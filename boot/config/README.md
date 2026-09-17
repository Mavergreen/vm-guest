# `config.plist`: every setting that is not a default, and why

`config.plist` is **our** OpenCore configuration. It is checked in as text so
that every setting is diffable, attributable and arguable.

## Where it came from, and where it deliberately did not

It was derived from **OpenCorePkg 1.0.7's own `Docs/Sample.plist`**, in the
same source tree `boot/build-opencore.sh` builds. Anything not listed below
is that sample's value, unchanged.

It was **not** derived from khronokernel's `config.plist`, the one inside the
reference `EFI-LEGACY.img` that P1 and P2 booted (inventoried in
`docs/utm-bundle-config.md`). That file targets OpenCore 0.6.6 — five years
and roughly twenty schema revisions stale. Porting it forward would have
meant carrying settings nobody here can explain, which is the opposite of
what P3 is for. The reference config is used as **evidence** instead: where
it made a choice, that choice is cited below and either adopted with a reason
or rejected with a reason.

Validation is `ocvalidate` from the same build:

```
"$MQG_BUILD_DIR"/OpenCorePkg-1.0.7/Utilities/ocvalidate/ocvalidate boot/config/config.plist
```

It announces that it is "only compatible with OpenCore version 1.0.7", which
is exactly why it is the validator we use rather than eyeballing the plist.
It reports **no issues**.

The file is serialised by Python's `plistlib` with sorted keys, so it
round-trips byte-identically and a `git diff` shows only what actually
changed. Regenerating by hand and re-sorting will not produce spurious
churn.

## How to read this document

Each entry says what changed, **why**, and what the evidence is. Three kinds
of evidence appear:

- **P1 observation** — something this project watched happen, cited to
  `NOTES.md`.
- **Reference config** — what khronokernel's 0.6.6 config does, cited to
  `docs/utm-bundle-config.md`. Suggestive, not binding: it was verified under
  TCG on Apple Silicon, and P1 already found one place where it is wrong for
  KVM.
- **Property of 10.9** — a fact about the guest OS, e.g. that it predates a
  technology entirely.

Anything with no entry below is a 1.0.7 sample default we did not touch. If
you are looking for a setting and cannot find it here, that is the answer:
nobody chose it, and changing it is fair game.

---

## The two load-bearing settings

### `PlatformInfo > Generic > SystemProductName` = `iMac14,2`

**Evidence: P1 observation.** The reference config sets `MacPro5,1`
(`docs/utm-bundle-config.md`). Under KVM on this host that produces an
immediate kernel panic in `AppleTyMCEDriver`, the Xeon machine-check driver,
which loads *because* the SMBIOS says the machine is a Xeon Mac Pro and then
faults on a CPU that is not one. See `NOTES.md`, "Failure 3: kernel panic in
AppleTyMCEDriver" and "What fixed it: SMBIOS".

Changing the model to `iMac14,2` attacks what the driver matches on rather
than trying to stop it loading, and the panic disappeared.

Note the honest caveat recorded in `NOTES.md`: `iMac14,2` is a 2013 Haswell
iMac and the guest CPU is advertised as Penryn. That pairing is odd and 10.9
evidently tolerates it. It is the first model that worked, not a model that
was shown to be best.

### `UEFI > Drivers` — `OpenHfsPlus.efi`, never `HfsPlus.efi`

**Evidence: `docs/decisions/0002-openhfsplus-over-apple-hfsplus.md`.** OVMF
cannot read HFS+, so OpenCore needs an HFS+ driver to see the installed
system at all. The reference image uses `HfsPlusLegacy.efi`, which is
extracted from Apple firmware: no source, no way to rebuild it, Tier 2 by
construction. Removing it is the entire reason P3 exists.

`OpenHfsPlus.efi` is built from pinned source by `boot/build-opencore.sh`.
Decision 0002 expects it to be slower and asks P3 to measure by how much;
that measurement needs a booting image and has not been taken yet.

Three drivers are loaded, in this order:

| Driver | Why |
|---|---|
| `OpenRuntime.efi` | Provides `OC_FIRMWARE_RUNTIME`. Every `Booter > Quirks` entry below needs it; without it they silently do nothing. |
| `OpenPartitionDxe.efi` | Reads Apple's partition layout (APM, and the Apple Boot partition scheme). In the reference image too. |
| `OpenHfsPlus.efi` | The HFS+ filesystem driver, per above. |

All three are `Enabled`, `LoadEarly: false`, no arguments — the sample's
shape for each. The sample ships fifty driver entries, forty-seven of them
disabled examples; those are removed rather than left disabled, so the list
is the list.

---

## Kernel

### `Kernel > Add` — `Lilu.kext`, then `VirtualSMC.kext`

**Evidence: P1 observation.** SMC emulation is what makes `DSMOS has arrived`
appear; without it 10.9 will not finish booting. P1 saw that line with
OpenCore-injected kexts and no `-device isa-applesmc` anywhere, which is why
this project needs no OSK string at all (`NOTES.md`, "Boot progress after the
fix").

Order is load-bearing: `VirtualSMC.kext`'s `Info.plist` declares
`OSBundleLibraries > as.vit9696.Lilu = 1.2.0`, so Lilu must be injected
first.

`MinKernel` is `8.0.0` and `MaxKernel` is empty, matching the sample's own
entries for these two kexts and also matching what the kexts themselves
declare (see below). `Arch` is `Any`; both binaries are fat with x86_64 and
i386 slices.

**The reference image ships a third SMC kext, `FakeSMC-32.kext`, and we do
not.** `FakeSMC` and `VirtualSMC` are *alternative* SMC emulators from
different projects; shipping both is unusual and at least one is probably
redundant. P1 never tested which. The rule here is that nothing ships without
having seen a boot fail without it, so we start with two and add back only on
evidence. **That experiment is Task 6 step 5 and has not been run** — it
needs a bootable configuration first.

#### Which releases, and whether they still support 10.9

`vendor/sources.tsv` pins:

| Kext | Release | Why this version |
|---|---|---|
| `Lilu` | 1.7.2 | The current release as of 2026-09-17. Pinned to the exact tag, never `latest`. |
| `VirtualSMC` | 1.3.7 | The current release as of 2026-09-17, and it requires Lilu ≥ 1.2.0, which 1.7.2 satisfies. |

These are the only things in the assembled EFI image that are not built from
source: **Tier 1**, acidanthera release binaries, pinned by tag and by
SHA-256. We cannot make them Tier 0 without building them, which needs Xcode.

acidanthera has been dropping old-OS support over time, so "current release"
is not by itself a reason to believe these load on 10.9. That was checked
concretely, by reading each `Contents/Info.plist` rather than by assuming:

```
Lilu 1.7.2        OSBundleLibraries_x86_64: com.apple.kpi.* = 10.0.0
VirtualSMC 1.3.7  OSBundleLibraries_x86_64: com.apple.kpi.* = 10.0.0
                                            as.vit9696.Lilu = 1.2.0
```

A `com.apple.kpi.*` version is a Darwin version. `10.0.0` is Darwin 10, which
is Mac OS X 10.6. **10.9 is Darwin 13**, comfortably above that floor, so
both kexts still declare support for it. (The non-architecture-specific
`OSBundleLibraries` in each declares `8.0.0`, Darwin 8 = 10.4, which is where
the `MinKernel: 8.0.0` above comes from.) Neither Mach-O carries an
`LC_VERSION_MIN_MACOSX` or `LC_BUILD_VERSION` load command, so there is no
second, stricter minimum hiding in the binary.

Had either declared a minimum above 13, that would have been a real
constraint needing older pinned releases — a decision, not a workaround.
It did not.

### `Kernel > Block` — empty, deliberately

**Evidence: P1 observation, and an unresolved question.** The reference
config ships a `Kernel > Block` entry for `com.apple.driver.AppleTyMCEDriver`
with `Enabled: false`. P1 flipped it to `true` and **nothing changed** — same
panic, same backtrace (`NOTES.md`, "Failure 4: the shipped fix did not
work"). Why it had no effect is still unknown.

So we ship no block at all. Carrying forward a setting that was observed to
do nothing would be cargo cult, and it would also confound Task 8, which
exists to prove that the SMBIOS change alone is what fixed the panic.

### `Kernel > Emulate > DummyPowerManagement` = `true`

**Evidence: reference config, corroborated by P1.** The reference sets it,
and P1's boot log shows the expected consequence:

```
ACPI_SMC_PlatformPlugin::start - waitForService(AppleIntelCPUPowerManagement) timed out
```

That timeout is harmless and is what this quirk buys: `AppleIntelCPUPower-
Management` cannot drive a virtual CPU, and without the stub it panics
instead of timing out.

### `Kernel > Quirks > PanicNoKextDump` = `true`

**Evidence: P1 observation.** P1's diagnosis rested entirely on being able to
read a panic backtrace off the screen. Without this quirk a panic is followed
by a dump of every loaded kext, which scrolls the useful part away. The
reference config sets it too.

### `Kernel > Quirks` settings we did **not** copy from the reference

- **`DisableLinkeditJettison`** is on — but it is already 1.0.7's sample
  default, so this is agreement, not a decision.
- **`SetApfsTrimTimeout`** is left at the sample default `-1`. The reference
  sets it. 10.9 predates APFS by four years and cannot mount an APFS volume,
  so the setting has nothing to act on here. This is the clearest example in
  this file of a reference setting that is *copied* rather than *chosen*.

---

## Booter

### `Booter > Quirks > AllowRelocationBlock` = `true`

**Evidence: reference config.** This is the only Booter quirk we had to
change: 1.0.7's sample already enables `AvoidRuntimeDefrag`,
`EnableWriteUnprotector`, `ProvideCustomSlide` and `EnableSafeModeSlide`, the
other four the reference turns on.

`AllowRelocationBlock` lets `boot.efi` be loaded into a relocation block when
the lower memory it wants is occupied. It is specifically a legacy-macOS
accommodation and the reference config, which is the only verified 10.9
configuration we have, enables it.

**None of the five has been re-tested on 1.0.7.** They are inherited from a
0.6.6 configuration on a different hypervisor. Task 7's failure tree changes
one quirk at a time if the boot misbehaves.

### Two Booter quirks where we keep 1.0.7's default over the reference's

The reference config leaves `SetupVirtualMap` **off**; 1.0.7's sample has it
**on**, and we keep it on. It corrects `SetVirtualAddresses` handling on
firmware that mishandles it, and it is what OVMF-based setups generally use.
The same applies to `FixupAppleEfiImages`, which did not exist in 0.6.6 at
all.

Both are recorded here because a reader comparing our config to
`docs/utm-bundle-config.md` will notice the difference and deserves to know
it was seen. If Task 7's boot fails in the booter, these are the first two
things to try flipping — one at a time.

---

## Misc

### `Misc > Security > ScanPolicy` = `0`

Scan everything. The sample's `17760515` restricts scanning to particular
device and filesystem types, and an HFS+ volume on a USB-attached disk —
which is exactly our layout, per `docs/utm-bundle-config.md` — is a good way
to end up with an empty picker and no explanation of why.

### `Misc > Security > SecureBootModel` = `Disabled`

**Property of 10.9.** Apple Secure Boot arrived with the T2, in 2018. 10.9 is
from 2013 and has no notion of it; leaving the sample's `Default` would ask
OpenCore to enforce a policy the OS cannot participate in.

### `Misc > Security > Vault` = `Optional`

The sample ships `Secure`, which requires a signed `vault.plist` and
`vault.sig` alongside the config. We do not produce those, and with `Secure`
set OpenCore refuses to boot at all. `Optional` is the honest value for a
configuration that is not vaulted. Note what this means: the config on the
EFI image is not tamper-evident. It is reproducible instead — rebuild the
image from this repo and compare.

### `Misc > Debug > DisableWatchDog` = `true`

**Evidence: `docs/decisions/0002`.** Decision 0002 expects `OpenHfsPlus.efi`
to be slower than Apple's driver by an unmeasured amount. The firmware
watchdog reboots the machine if `boot.efi` takes too long, which would turn
"slow" into "reboots forever" and make the cause very hard to see. Off during
bring-up.

### `Misc > Boot > HideAuxiliary` = `false`

The sample hides auxiliary picker entries behind a keystroke. During
bring-up, an entry hidden behind a keystroke is indistinguishable from an
entry that OpenCore never found — and "picker empty" is one of the failure
modes Task 7 explicitly has to diagnose. Show everything.

### `Misc > Security > ExposeSensitiveData` = `6` (sample default, kept on purpose)

Not a change, but worth knowing it is load-bearing: bit `0x2` is what makes
OpenCore write its version into NVRAM, which is how Task 7 confirms it booted
*our* 1.0.7 build and not the old 0.6.6 image lying around. Turning this off
would remove the only direct evidence of which bootloader ran.

### `Misc > Tools` — empty

The reference image ships `OpenShell.efi`. We do not collect it from the
build (`boot/build-opencore.sh` names five artifacts and that is not one of
them), so listing it would name a file that is not there. The
`::/EFI/OC/Tools` directory is created empty for the day we want one.

---

## NVRAM

The sample's NVRAM section is an assortment of example values for a real Mac.
It was replaced rather than edited, keeping three variables under Apple's
boot GUID `7C436110-AB2A-4BBB-A880-FE41995C9F82`:

| Variable | Value | Why |
|---|---|---|
| `boot-args` | `-v keepsyms=1` | Verbose boot. Every P1 diagnosis came from reading the boot text, and `keepsyms=1` is what makes a panic backtrace show symbol names instead of raw addresses. |
| `prev-lang:kbd` | `en-US:0` | Stops the first-boot language picker. The sample's value is `ru-RU:252`. |
| `run-efi-updater` | `No` | Stops Apple's EFI firmware updater from trying to flash firmware that does not exist. |

`NVRAM > Delete` removes `boot-args` before adding it. That matters from Task
8 onwards: once the split-pflash OVMF restores EFI variable *persistence*, a
`boot-args` left in the variable store from an earlier experiment would
otherwise outlive the config that set it, and a one-variable-per-experiment
lab cannot afford that.

Dropped from the sample, each for a reason:

- **`csr-active-config`** — System Integrity Protection arrived in 10.11.
  10.9 has no SIP to configure. Copied-not-chosen if left in.
- **`SystemAudioVolume`, `ForceDisplayRotationInEFI`,
  `DefaultBackgroundColor`** — cosmetics for a physical Mac.
- **`rtc-blacklist`** — for working around specific real-hardware RTC bugs.
- **`NVRAM > LegacySchema`** — the whole block. It governs NVRAM emulation
  for firmware with no working variable store, which requires a legacy NVRAM
  driver we do not load.

---

## PlatformInfo

`UpdateSMBIOSMode` is `Create`, which is both the sample default and what the
reference config uses: OpenCore builds new SMBIOS tables rather than
overwriting the firmware's, which is the mode that works when the firmware's
own tables are not Apple-shaped.

`Automatic` is `true`, so the `Generic` section is what takes effect.

**The identity fields are left at the sample's obvious placeholders** —
`SystemSerialNumber` `W00000000001`, `SystemUUID` all zeroes, `MLB`
`M0000000000000001`, `ROM` `112233445566`. This is deliberate, not an
oversight. Generating a plausible serial number is what you do when you want
a VM to pass for a real Mac to Apple's servers; we want the opposite, and
nothing in this project logs into anything. A reader who sees a real-looking
serial number in a future diff should ask why it changed.

---

## UEFI

### `UEFI > APFS > EnableJumpstart` = `false`

**Property of 10.9.** APFS jumpstart loads an APFS driver out of an APFS
container so the firmware can see APFS volumes. 10.9 cannot mount APFS at
all; there is nothing for it to find. The sample defaults it on because
almost everyone running OpenCore is on a much newer macOS.

### Everything else under `UEFI`

Sample defaults, including `Input > KeySupport: true` (the guest's keyboard is
USB through the firmware, per `docs/utm-bundle-config.md`), `ConnectDrivers:
true`, and `Quirks > RequestBootVarRouting: true` (which pairs with
`OpenRuntime.efi`). `ReservedMemory` and `Unload` are emptied of the sample's
examples.

---

## What is still unverified

Written down because a config that has never booted is a hypothesis:

1. **Nothing here has booted anything.** That is Task 7.
2. **The five Booter quirks are inherited from 0.6.6 under TCG**, not
   re-tested on 1.0.7 under KVM.
3. **Whether `FakeSMC-32` was redundant** — Task 6's experiment, which needs
   a working boot first.
4. **The `OpenHfsPlus` vs Apple `HfsPlus` boot-time cost** that decision 0002
   asks P3 to measure.

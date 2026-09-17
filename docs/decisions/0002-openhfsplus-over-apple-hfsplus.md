# 0002 — Use `OpenHfsPlus.efi`, not Apple's `HfsPlus.efi`

Date: 2026-09-17
Status: accepted; measured in P3 (see "Measured cost" below)

## Context

OVMF cannot read HFS+, so OpenCore needs an HFS+ EFI driver to find and boot
the installer and the installed system.

Two options exist. `HfsPlus.efi` is Apple's own driver, extracted from Mac
firmware images; it is the common choice and reportedly the faster one.
`OpenHfsPlus.efi` is built from source as part of OpenCorePkg.

## Decision

Use `OpenHfsPlus.efi`.

## Reasoning

Apple's `HfsPlus.efi` is Tier 2 by construction — a binary extracted from
somewhere, with no source and no way to rebuild it. The user's constraint is
explicit: no custom blobs that cannot be reproduced. A driver that can never
be built from source cannot be in the shipped boot path, regardless of how
convenient it is.

`OpenHfsPlus.efi` is Tier 0: pinned source, built by our own
`boot/build-opencore.sh`.

## Consequences

- Boot is expected to be slower. **P3 must measure how much**, and record the
  number here. If the cost turns out to be large rather than marginal, the
  user can overrule this decision knowingly — which is the point of measuring
  rather than assuming.
- Measured cost: **+3.3 seconds on a ~46-second boot (+7.2%)**. See below.

## Measured cost, 2026-09-17 (P3 Task 9)

**`OpenHfsPlus.efi` costs 3.3 s more than Apple's `HfsPlusLegacy.efi` to
reach the Mavericks desktop: 49.1 s against 45.8 s.** That is real and
repeatable — it is nine times the run-to-run spread — and it is small.

| Driver | Runs | Launch → desktop | Spread |
|---|---|---|---|
| `OpenHfsPlus.efi` (Tier 0, ours) | 5 | **49.1 s** mean | 48.8–49.7 s |
| `HfsPlusLegacy.efi` (Tier 2, Apple's) | 5 | **45.8 s** mean | 45.7–46.0 s |

Method. Ten boots, strictly alternating so any host drift falls on both
arms. Each run starts from identical state: a fresh qcow2 overlay off
golden #1 and a pristine NVRAM, since 10.9 ignores the ACPI power button
and every run therefore ends in a hard kill. **Exactly one line of the QEMU
command differs between the two arms** — the OpenCore image — and the two
images differ only in which driver is in `EFI/OC/Drivers/` and which one
`config.plist` names. Same OpenCore 1.0.7, same config, same kexts, same
firmware, same disk. Timing is host-side: t=0 is the QEMU exec, and the end
is the first 1 Hz `screendump` over the monitor socket in which more than
half the frame is lit, which is the Finder desktop (confirmed by eye, not
by the number alone — see the instrument lesson in `NOTES.md`). Sampling
resolution is therefore ±1 s, which is why five runs per arm and not one.

**The decision stands, and by a wider margin than expected**, because of
what the measurement could not be run on.

**Apple's driver does not load on the firmware we ship at all.** On
`p3-full` — our OVMF, built from the pinned `acidanthera/audk` tree — the
boot stops dead:

```
OC: Driver HfsPlusLegacy.efi at 2 cannot be loaded - Not started!
Halting on critical error
```

`EFI_NOT_STARTED` comes out of `gBS->LoadImage`, from
`UefiImageInitializeContextPreHash` in audk's
`MdeModulePkg/Core/Dxe/Image/Image.c`. audk replaces EDK II's tolerant PE
loader with acidanthera's strict one, and Apple's extracted binary is not a
conformant PE image, so it is refused before it runs. `FixupAppleEfiImages`
was already enabled and does not help: it fixes images OpenCore loads
itself, not ones the firmware loads.

So the comparison above had to be made on the **reference** firmware (the
Tier 2 OVMF from the UTM bundle, whose 2021-era EDK II loader accepts the
blob), holding our OpenCore, our config and our kexts constant. The number
is honest about the driver and says nothing about the firmware; for
reference, `OpenHfsPlus` measured 48.7–50.0 s on the shipped firmware too,
so the firmware change costs nothing here.

The irony is worth stating plainly: **acidanthera's own EDK II fork will not
load Apple's `HfsPlus` driver.** Tier 2 here is not merely a policy
violation, it is a compatibility one. Overruling this decision would mean
giving up the self-built firmware as well — trading 3.3 seconds for two
unbuildable blobs instead of one.

Two caveats, so this is not over-read:

- This is one host, one guest, one golden. `docs/host-profile.md` §4 is
  where host-specific claims go; this one is not recorded there because the
  *ratio* is unlikely to be host-specific even if the absolute times are.
- It measures **boot**, which is the only thing this decision is about.
  `OpenHfsPlus` is not in the path once macOS has mounted the volume with
  its own driver, so nothing about steady-state guest performance follows.

## Addendum, 2026-09-17: derived images stay in the quarantine

P1 needed a modified OpenCore image (SMBIOS changed to stop an
`AppleTyMCEDriver` panic). The patched copy was first written to
`$MQG_IMAGE_DIR/work/`, which made `bin/tier-check.sh` report Tier 2 clean --
the profile no longer named the quarantine, even though it still depended on
an unbuildable blob.

**Deriving from a Tier 2 artifact does not launder it.** Modified copies live
in `$MQG_VENDOR_DIR/derived/`, inside the quarantine, so the gate keeps
seeing them. A gate a copy can walk out of is decorative.

This also sharpens what P3 has to deliver: not "an OpenCore image with our
settings", but one built from pinned OpenCorePkg source with those settings.

# Mavericks install: the click-log

Every step of the P2 manual install, in order, with enough detail that P4's
unattended pipeline can be written against it. This document is the
specification that automation follows; anything not written here has to be
rediscovered later.

Screenshots referenced below live in `$MQG_IMAGE_DIR/screenshots/`, outside
the repo — they are numerous and the repo is on NFS. Capture one at any time
with `./vm/screenshot.sh <label>`, which works while someone is using the GTK
window.

- **Profile:** `p1-interactive` (= `p1-reference` + a native GTK window)
- **Date:** 2026-09-17
- **QEMU command line:** see `run.log`; the profile expands to 45 arguments
- **Media:** `InstallMavericks.iso`, the ISO produced by `hdiutil convert
  -format UDTO` from `get.sh`'s dmg on an Intel Mac
- **Guest:** 4096 MB, 2 vCPUs, Penryn+ssse3/sse4.1/sse4.2, q35 with
  `vmport=off`

## Getting to the installer

| # | Screen | Action | Notes |
|---|---|---|---|
| 1 | OpenCore picker | boots automatically | No EFI variable persistence (`-bios`), so there is nothing to remember between runs |
| 2 | Verbose kernel boot | none | ~40 s from launch to GUI. `DSMOS has arrived` confirms SMC emulation works |
| 3 | Language picker | "Use English for the main language" → **→** | `01-language-picker.png` |
| 4 | OS X Utilities | **Disk Utility** | Do NOT pick "Reinstall OS X" first: the target disk is unformatted and will not be offered as a destination |

## Disk Utility

The target appears as **64.42 GB QEMU HARDDISK** with nothing indented beneath
it. The 200 MB disk below it holding `EFI-LEGACY` is the OpenCore image —
leave it alone.

| # | Screen | Action | Notes |
|---|---|---|---|
| 5 | Disk Utility | select the **64.42 GB QEMU HARDDISK** (the drive, not a volume) | `06-disk-utility.png` |
| 6 | **Partition** tab | Partition Layout → **1 Partition** | Use Partition, not Erase: on a whole drive, the partition *scheme* is only settable here |
| 7 | Options… | **GUID Partition Table** | **The step that matters.** APM will not boot under OpenCore/UEFI, and getting it wrong is not visible until after a full install |
| 8 | Partition Information | Name `Mavericks`, Format **Mac OS Extended (Journaled)** | |
| 9 | | **Apply** → Partition | `07-partitioned.png` |

Verified afterwards from the Disk Utility footer:

- Partition Map Scheme: **GUID Partition Table**
- Total Capacity: 64.42 GB (64,424,509,440 bytes)
- **Connection Bus: SATA** — worth noting, because the profile says
  `-device ide-hd,bus=ide.0`. On q35 those ports are AHCI, so this is the AHCI
  path the design asked for rather than legacy IDE.

## Installer

| # | Screen | Action | Notes |
|---|---|---|---|
| 10 | ⌘Q | quit Disk Utility | returns to OS X Utilities |
| 11 | OS X Utilities | **Reinstall OS X** → Continue | |
| 12 | Licence | Agree | |
| 13 | Destination | select `Mavericks` → **Install** | `08-installing.png` |

- **Install started:** 2026-09-17T17:42:13Z
- **Installer's own estimate:** "about 24 minutes remaining"
- **Actual wall-clock:** _to be filled in_

## First boot and Setup Assistant

**Decided in advance**, so the baseline is deliberate rather than whatever got
clicked: a **minimal local account**, skipping everything skippable.

- Account short name: **`mavsuser`**
- **No Apple ID**, skip iCloud, skip registration, decline diagnostics

Rationale: golden #1 is the baseline every P5 experiment is measured against,
so it should carry as little incidental state as possible. An Apple ID would
also bake credentials into an image the project rule says must never be
published, and would complicate every clone made from it.

Every screen and field below — this is the part P4 replaces with
`.AppleSetupDone` and a first-boot payload, so the list of what Setup
Assistant actually asks *is* the specification for it.

| # | Screen | Action | Notes |
|---|---|---|---|

## Post-install state

_To be filled in._

- Account name / uid:
- Hostname:
- Network: DHCP? DNS resolving?
- Clock correct?
- `sw_vers` output:

## Capability census

_To be filled in after first boot. This is the honest-limitations list the
final report owes the user, and writing it early stops it reading like an
excuse later._

| Capability | State | Notes |
|---|---|---|
| Sound | | `intel-hda` is in the bundle but not yet in our profile |
| Resolution changes | | which are offered? does 10.9 see `vgamem_mb=64`? |
| Sleep | | |
| Shutdown from the Apple menu | | |
| Reboot | | |
| Networking | | `usb-net`; `AppleUSBCDCECMData` loads during boot |
| DNS | | Kostarelas needed 1.1.1.1 |
| Clock accuracy across a reboot | | |
| Safari / TLS against a modern site | | Kostarelas found the modern web mostly broken |
| Pointer feel | | P5 baseline. Relative `usb-mouse`, so a grab is required |
| App Store / Apple ID | | |

## Deferred post-install changes

Apple's 2016 security update and Mavericks Forever's post-install hardening
script are both candidates. **Neither is applied**, and neither should be
without asking first.

The reason is measurement, not caution for its own sake: golden #1 is the
baseline every P5 experiment is compared against. A hardening script that
silently disables a service makes every later number unattributable, and
nobody will remember it was applied.

_To be filled in: what each one changes, whether it is reversible, and whether
it would plausibly affect performance._

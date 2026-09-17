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
- **Actual wall-clock: 14 minutes** (17:42:13Z → ~17:56Z), against the installer's own 24-minute estimate. Useful for P6's job-time budget: the install is not the long pole a naive reading of the estimate suggests.

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
| 14 | Reboot | automatic when the install finishes | |
| 15 | OpenCore picker | **auto-picked the Mavericks volume** | Worth noting: no NVRAM persistence, yet it still chose the installed system over the attached installer ISO |
| 16 | Setup Assistant | region, keyboard, no transfer, **skip Apple ID**, agree, create `mavsuser`, skip iCloud Keychain, decline diagnostics | |
| 17 | Desktop | | `11-desktop.png` |

## Post-install state

Verified in the guest's own Terminal rather than assumed — `12-terminal.png`.

```
ProductName:    Mac OS X
ProductVersion: 10.9.5
BuildVersion:   13F34
```

| | |
|---|---|
| Account | `mavsuser`, uid 501, gid 20 (staff) |
| Admin? | yes — in group 80 (admin) |
| Hostname | `Maverickss-iMac.local` — Setup Assistant derived it from the full name; P4 should set this deliberately |
| Boot volume | `/dev/disk0s2`, 59 GiB, **8.8 GiB used**, 50 GiB free |
| `hw.model` | **`iMac14,2`** — our OpenCore SMBIOS override is in effect in the installed system, not only in the installer |
| `hw.ncpu` | 2 |
| `hw.memsize` | 4294967296 (4 GiB) |

The account is already a member of `com.apple.access_ssh` and
`com.apple.access_screensharing`, which is ordinary for an admin user and does
**not** mean either service is enabled. Remote Login is still off.

## Capability census

_To be filled in after first boot. This is the honest-limitations list the
final report owes the user, and writing it early stops it reading like an
excuse later._

| Capability | State | Notes |
|---|---|---|
| Sound | **absent** | No output device at all. Expected: `intel-hda` is in the reference bundle but deliberately left out of our profile to reduce variables. Cheap to add. |
| Resolution changes | **none — 1280x720 only** | See below; the most informative finding here. |
| Sleep | offered, not exercised | Deliberately untested: sleep/wake is a good way to corrupt a guest, and there is no reason to risk it before a golden exists. P5's job. |
| Shutdown | **works, promptly** | Both from the Apple menu and via ACPI `system_powerdown` from the QEMU monitor, which matters for scripted use in P4/P6. |
| Reboot | **clean** | Hits the OpenCore picker, which defaults to Mavericks and auto-selects after a few seconds. Roughly 30 s to the desktop by eye; a measured figure comes from a timed boot on a clone. |
| Networking | **works** | `usb-net` + slirp. `dig` resolves and `curl` completes an HTTP request. No configuration was needed. |
| ICMP / `ping` | **fails, and cannot work here** | Not a guest problem — see below. |
| DNS | **works out of the box** | Notable: Kostarelas needed to set the resolver to 1.1.1.1 and khronokernel documents a `scutil` recipe for the same problem. Neither was necessary here. Do not carry that step forward into P4 without re-testing whether it is still needed. |
| Clock accuracy across a reboot | **correct** | Guest clock matched the host across the install reboot and a later clone boot. Kostarelas's advice to check the clock first when Apple servers fail was not needed. |
| Safari / TLS against a modern site | | Kostarelas found the modern web mostly broken |
| Pointer feel | **fine enough** (user's words) | Relative `usb-mouse`, so a grab is required. `usb-tablet` does nothing on 10.9 without pmj's kext. |
| Window drag / resize | **smooth enough to use** (user's words) | P5 baseline. Notable given there is no graphics acceleration at all: the CPU is drawing everything. |
| App Store / Apple ID | | Deliberately not signed in. |

### `ping` failing is a host artifact, not a guest limitation

Both `ping 1.1.1.1` and `ping apple.com` fail. The obvious reading is "the
guest has no network", and it would have gone into this table as such.

It is wrong. QEMU's user-mode networking (slirp) can only forward ICMP if the
host lets the QEMU process open unprivileged ICMP sockets, and on this host:

```
$ sysctl -n net.ipv4.ping_group_range
1	0
```

That is an **empty** range — start 1, end 0 — so no group at all may open
them. QEMU runs as the user, so slirp cannot carry ping under any
circumstances here. Meanwhile the guest discovered an AirPlay device on the
LAN, which needs a working network stack.

Recorded because it is a trap: anyone debugging guest networking with `ping`
on this host will chase a fault that is not there. Use a TCP test instead.

### 10.9 offers exactly one resolution, and VRAM is not why

System Preferences → Displays offers **only 1280x720**.

This is worth more than it looks. Kostarelas saw about 3 MB of VRAM under UTM
and could not pass a parameter to change it; the design took that as the
constraint and made "try `vgamem_mb=64` and see whether 10.9 notices" an early
experiment. We gave it 64 MB — twenty times what he had — and 10.9 still
offers a single mode.

So **VRAM was never the limiting factor**.

**The rest of what this section originally said was wrong, and P3 corrected
it.** It concluded that the limit was stock `-vga std` having no 10.9
mode-setting driver, and that the real work was therefore a display driver.

P3's boot, with our own OpenCore and no display driver whatsoever, came up at
**4096x2160**. The lever is `UEFI > Output > Resolution` in the bootloader's
config: OpenCore sets the UEFI GOP framebuffer and macOS inherits it. See the
P3 entry in `NOTES.md`.

What remains true: the framebuffer is *fixed*, so the guest still cannot
change resolution at runtime, and resize-to-window still needs driver work.
But reaching a usable resolution was never a driver problem.

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

## Auto-login is on

The clone boots straight to a logged-in desktop with no password prompt. Setup
Assistant enables auto-login for a single-user system.

This is convenient and load-bearing for later phases — an unattended boot in
P4 or P6 is not going to stall at a login window — but it also means the
golden image grants a desktop session to anyone who can boot it. Fine for a
local, never-published image; worth stating rather than discovering.

## Measured numbers

| What | Value | How |
|---|---|---|
| Install | **14 min** | wall clock, 17:42:13Z to ~17:56Z, against the installer's own 24-minute estimate |
| Boot to desktop | **39.3 s** | measured host-side by polling `screendump` until the framebuffer showed a GUI, on a clone of golden #1 |
| Installed size | **8.54 GiB** | `qemu-img info`, of a 60 GiB virtual disk |
| Golden promotion | **19 s** | almost entirely SHA-256; the copy itself is a btrfs reflink |

The 39.3 s includes the OpenCore picker's timeout, so it is a
launch-to-usable figure rather than a kernel boot time. That is the number
that matters for iteration speed anyway.

## Absolute pointing: it needed no kext, and I got this wrong

**Outcome: `usb-tablet` works natively on 10.9. No third-party kext is
installed, and none is needed.**

The wrong version of this section is worth preserving, because the mistake
was a reasoning error rather than bad luck.

### What I claimed

P1's first attempt at `usb-tablet` produced a guest cursor pinned at the
top-left receiving no motion events. I concluded that OS X cannot drive
QEMU's tablet natively, and cited `pmj/QemuUSBTablet-OSX` existing at all as
confirmation — a third-party kext exists to solve this, therefore this is the
problem it solves. That went into `NOTES.md`, into `docs/prior-art.md`, and
into the design's risk list.

### Why it was wrong

That attempt ran on `qemu-xhci`. On the same controller the **keyboard was
also dead**. The controller was at fault, not the pointing device. I then
switched to `usb-mouse` (still XHCI, still dead), then to EHCI — where the
mouse worked — and never retried `usb-tablet` on EHCI before installing the
kext. So the kext was credited with a fix that the controller change had
already made.

The prior art fit the story, which is exactly what made it convincing.

### How it was settled

`kextstat | grep -i qemu` came back empty while absolute pointing was
working — the kext was not loaded and the tablet worked anyway.

Control experiment, `vm/profiles/p2-notablet-abs.args`: `usb-tablet` on EHCI
against a **fresh clone of golden #1**, which has never had the kext
installed and had no transfer disk attached. The pointer tracked correctly.

This is what the clone machinery is for. Testing the claim cost one clone and
two minutes, because throwing away a guest is free.

### The deeper reason the prior art misled me

The kext's README was accurate — for QEMU as it stood in 2016. Its author,
Phil Dennis-Jordan, then fixed the underlying bug *in QEMU* in January 2017
(commit `0cd089e937f2`): `usb-tablet` was advertising `bInterfaceProtocol`
0x02, a boot-protocol mouse it is not, and a HID usage of 0x01 (pointer),
which macOS treats as an analog stick rather than an absolute cursor.

So the kext was a stopgap that its own author obsoleted nine years ago. The
briefs inherited the 2016 description without noting the upstream fix, and I
inherited it from them. Prior art has a date, and this project's is mostly
2016–2021; "X does not work" from that era needs re-testing before it is
treated as a constraint.

### What this leaves

- `p1-reference` uses `usb-tablet`, giving absolute pointing with no grab.
- No third-party kext in the guest, and one fewer binary in
  `vendor/sources.tsv` — a strictly better outcome than the one we were
  aiming for.
- `pmj/QemuUSBTablet-OSX` stays in `docs/prior-art.md`, correctly described.
  It may matter for other controller or OS combinations. Nothing here
  depends on it.
- **Golden #2 is not needed.** Golden #1 remains the single baseline, and it
  is also the working image.

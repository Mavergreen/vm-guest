# 0002 — Use `OpenHfsPlus.efi`, not Apple's `HfsPlus.efi`

Date: 2026-09-17
Status: accepted, pending measurement in P3

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
- Measured cost: _to be filled in by P3._

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

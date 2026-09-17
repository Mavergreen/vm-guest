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

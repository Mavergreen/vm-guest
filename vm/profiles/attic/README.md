# Retired profiles

These are P1/P2/P3 scaffolding. They are kept because they record how the
working configuration was arrived at — each one is a step in a chain of
one-variable experiments, and the diffs between them are the evidence. They
are **not** kept because they still work, and they are **not** expected to
keep working as the project moves on.

## Why they are here and not in `vm/profiles/`

Every one of them boots a **Tier 2** blob: khronokernel's `EFI-LEGACY.img`
(or a patched copy of it), or the UTM bundle's `OVMF.bin`. Neither can be
rebuilt from source, which is precisely what
`docs/decisions/0002-openhfsplus-over-apple-hfsplus.md` and P3's exit gate
forbid in the shipped boot path.

P3's exit gate is `bin/tier-check.sh --strict`, which scans `PROFILE_DIR`
(`vm/profiles/`) and fails if any profile there resolves to a path under
`$MQG_VENDOR_DIR`. `attic/` is a subdirectory, and `profile_list` globs
`*.args` rather than recursing, so nothing here is scanned — and nothing
here is reachable by `./vm/run.sh <name>` either.

**The alternative was to weaken the gate to tolerate them, and that would
have inverted the point of having a gate.** A rule with a standing exemption
for the things that break it is not a rule. Moving them out of the scanned
set says what is true: they are history, not part of the shipped boot path.

## What each one was

| Profile | What it was for |
|---|---|
| `p1-reference.args` | Kostarelas's working UTM configuration, translated to plain QEMU/KVM. The first thing that booted. Reference OVMF via `-bios`, khronokernel's OpenCore over USB. |
| `p1-headless.args` | `p1-reference` with `-display none` and a monitor socket, so boot could be screenshotted without a window. |
| `p1-interactive.args` | `p1-reference` in a GTK window. This is what the 10.9.5 install was driven in; see `docs/install-log.md`. |
| `p2-clone.args` | A throwaway clone of golden #1, headless. The template every later one-variable experiment copied. |
| `p2-notablet-abs.args` | The control experiment that showed `usb-tablet` works on EHCI with no third-party kext, correcting an earlier claim. |
| `p3-oc.args` | One variable from `p2-clone`: **our** OpenCore, built from pinned source, on the reference firmware. Proved the bootloader half before the firmware half. |

`p3-oc` is here for a subtler reason than the rest, and it is worth stating
because it is a hole this directory closes. Its firmware line reads
`-bios %IMAGES%/work/OVMF_CODE.fd`, so `tier-check` saw no `%VENDOR%` and
reported it clean — but that file is **byte-identical** to the UTM bundle's
`OVMF.bin` (sha256 `8a7ef535…`), a Tier 2 blob that had been copied into
`work/`. The profile's own header says "the firmware still is [Tier 2],
which is why tier-check will keep flagging this profile until p3-full", and
tier-check never did. This is exactly the laundering the addendum to
`docs/decisions/0002` forbids, arriving by a route that addendum did not
anticipate: not a *modified* copy in `work/`, an *unmodified* one.

**The gate is textual and this is its known blind spot:** it matches the
resolved `$MQG_VENDOR_DIR` path in an expanded profile, so a Tier 2 blob
copied anywhere else is invisible to it. See
`docs/decisions/0004-p3-boot-stack-provenance.md`.

## If you want to run one anyway

Copy it back to `vm/profiles/` temporarily, fetch whatever it needs into
`$MQG_VENDOR_DIR`, and **do not commit it there** — `./bin/run-tests.sh`
will fail on `tier-check --strict` if you do, which is the gate working.

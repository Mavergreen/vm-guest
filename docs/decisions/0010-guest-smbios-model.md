# 0010 — The guest's SMBIOS is a parameter, and G14's explanation is still untested

Date: 2026-09-21
Status: accepted, on measurement. The default does not change.

`docs/host-profile.md` G14 has said the same thing since P1:

> SMBIOS must not be `MacPro5,1` — it loads `AppleTyMCEDriver`, which
> panics on a non-Xeon CPU. Using `iMac14,2`.

Two claims are welded together there, and only one of them is a
measurement.

**The observation** is that a guest panicked with `MacPro5,1` and stopped
panicking with `iMac14,2`, on this host, on 2026-09-17.

**The explanation** — *because `AppleTyMCEDriver` is the Xeon machine-check
driver and faults on a CPU that is not one* — was reasoning. It has never
been tested, and only a Xeon host can test it. `docs/test-hosts.md` has
said so plainly for days: *"If it panics anyway, my explanation of P1's
panic was wrong."*

This project has caught four inherited, undated claims wrong (the
`usb-tablet` kext, "DNS needs configuration", Security Update 2016-001,
`kvm.ignore_msrs=1`). An explanation of our own that nobody has tried to
falsify belongs in the same category, and it was sitting behind a hardcoded
string at `boot/config/config.plist:367` — so testing it meant editing a
tracked file and remembering to put it back. That is how an experiment goes
unrun for three phases.

## Decision

**`image/build-image.sh --smbios MODEL` sets the guest's SMBIOS product
name, and `lib/smbios.sh` carries a table of the models this project has
evidence for, each with a status and the evidence behind it.** Same shape
as `lib/cpu.sh` and ADR 0009, same reasons: the table is guidance, an
unlisted model warns and proceeds, and the manifest records an `smbios` row
saying which model the image was built with and what the table knew about
it at the time. `bin/triangulate.sh --smbios` passes it through to both
pipeline call sites.

**The default does not change.** It stays `iMac14,2`, which is the only
model with completed installs behind it — three of them, on three hosts and
three QEMUs.

## What `--smbios` changes, and what it deliberately leaves alone

OpenCore's `PlatformInfo > Generic` block in our config has seven fields.
`--smbios` touches **one**:

| Field | What we do | Why |
|---|---|---|
| `SystemProductName` | **changed** | The thing under test. It is what the guest reports as `hw.model` and what a kext matches on. |
| `SystemSerialNumber` (`W00000000001`) | untouched | A placeholder, not a valid serial for `iMac14,2` or anything else. |
| `MLB` (`M0000000000000001`) | untouched | Same. |
| `ROM` (`ESIzRFVm`) | untouched | Same. |
| `SystemUUID` (all zeros) | untouched | Same. |
| `SpoofVendor`, `SystemMemoryStatus` | untouched | Not model-specific. |

Changing the product name alone **is** coherent, and the reason is
`Automatic = true`: OpenCore looks the product name up in its own built-in
Apple model database and derives the board id, the firmware features and
the platform feature word from it. The evidence that this works is in P1's
own panic screen — it printed `System model name: MacPro5,1
(Mac-F221BEC8)`, and `Mac-F221BEC8` is a board id **nobody in this project
has ever typed**. OpenCore derived it from the product name we set.

The serials are left alone on purpose. They are not plausible values for
any Mac and were never meant to be: this guest does not talk to Apple's
servers, and minting realistic-looking serials for a machine that does not
exist is not something this project should do. A serial is also not what a
machine-check driver consults, so leaving them fixed keeps the experiment a
one-variable one — which is the whole point. **A half-changed SMBIOS would
produce a failure that is about our edit rather than about Apple's driver,
and that failure would look like a result.**

Two mechanical consequences of the same concern:

- The edit is **surgical text**, not a plistlib round-trip. One value
  changes and the bytes around it do not, so a default build still produces
  the config whose checksum is in every manifest this project has written.
  `smbios_plist_set` refuses a file that does not have exactly one
  `SystemProductName` key rather than guessing which one `PlatformInfo`
  reads.
- The derived config is **validated by the `ocvalidate` built from the same
  pinned OpenCore** before it is copied onto the EFI image.

One thing is refused outright, and it is not about evidence: a value
carrying `<`, `&`, a quote or whitespace. An unknown *model* is a host we
have not met; an unwritable *string* is a broken config.

## The control, run here first, because it was cheap

Before anyone drives to the Mac Pro, the question worth asking was whether
the 2026-09-17 observation still reproduces at all. Three phases and two
OpenCore versions later, it might simply have stopped being true — and that
would have been the cheapest possible answer.

Primary host (`pet-power-plant`, i7-8700B Coffee Lake, **not a Xeon**, QEMU
8.2.2, `-accel kvm`), an overlay on the `p2-manual-install` golden created
with `vm/clone.sh` so the golden was never written, no installer media, our
own OVMF and our own OpenCore 1.0.7, one changed string:

| SMBIOS | at 20 s | at 40–60 s | at 300 s | `vm/screenshot.sh` verdict |
|---|---|---|---|---|
| `iMac14,2` | boot text | Finder desktop | desktop | `185799 colours, 99.78% lit — graphical` |
| `MacPro5,1` | boot text | **panic** | same panic, frozen | `2 colours, 9.64% lit — text` |

**It reproduces.** The panic screen, captured at 300 s:

```
AppleTyMCEDriver::start coreVIDPID = 0xffffffff Number of packages = 1 ...
panic(cpu 0 caller 0xffffff800032dc43e): Kernel trap at 0xffffff7f849116b7,
  type 13=general protection
  com.apple.driver.AppleTyMCEDriver :
  __ZN16AppleTyMCEDriver47enableInterruptForCorrectableMemoryCoreRegisterEPv
Mac OS version: 13F34
System model name: MacPro5,1 (Mac-F221BEC8)
```

That is P1's backtrace, kext for kext, under a bootloader P1 never had, a
firmware P1 never had, and an **already-installed** guest rather than the
installer — so it is not a property of Apple's installer either.

Note the screenshot verdicts, because the difference between them is a
verdict and not a colour count: **2 colours is white-on-black text**, which
is what a panic looks like. Misreading a colour count as "blank screen"
cost an hour in P3.

## What this settles, and what it does not

**Settled:** the observation is solid on non-Xeon hardware. It survives
three phases, two OpenCore versions, two firmwares and installed-vs-
installer. The entry is not stale and the default is right to keep.

**Not settled, and unchanged by any of this:** *why*. Every observation is
still from one machine with one CPU. `AppleTyMCEDriver` loading because the
SMBIOS names a Xeon machine, and faulting because the CPU is not one, is
the same untested story it was in P1 — and the only difference now is that
it is labelled as one in `lib/smbios.sh`, in the ledger, and here.

## The experiment that settles it

`ap-juicer` (Mac Pro 1,1, Xeon 5150, Debian 13, QEMU 11.0.2) has run this
whole pipeline successfully with the default SMBIOS. It is a real Xeon, so
it is the machine that can settle the explanation:

```
vmavs triangulate --full --cpu Conroe --smbios MacPro5,1
```

- **It installs and answers SSH** → the driver was fine on a machine that
  really is a Xeon. The explanation survives, G14 is confirmed
  host-specific, and `g14_verdict` says CONFIRM by itself.
- **It panics** → the explanation is wrong. `AppleTyMCEDriver` is not
  discriminating on the CPU being a Xeon, and G14 keeps its advice while
  losing its reason. `g14_verdict` deliberately says **CANNOT-SAY** here
  and names the screenshot, because the panic reaches no log the harness
  can read; the ledger gets edited by hand once a human has read the
  backtrace.

The third outcome — the run stops in an earlier stage — is CANNOT-SAY and
says which stage. A verdict that asserts something false is worse than one
that says nothing; `g26_verdict` proved that yesterday.

## Alternatives considered

**Leave it hardcoded and edit the file for the experiment.** What we did
for three phases. The experiment did not get run.

**Make `MacPro5,1` unavailable, since it panics.** It panics *here*. The
entire question is whether it panics *there*, and a parameter that refuses
the interesting value cannot ask it. `lib/smbios.sh` warns loudly and
proceeds, exactly like `lib/cpu.sh`.

**Expose the whole `PlatformInfo` block.** Six more knobs, no evidence
behind any of them, and a much larger surface for a failure that is about
our edit. One field, one question.

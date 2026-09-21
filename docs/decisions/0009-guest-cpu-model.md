# 0009 — The guest CPU is a choice from a tested list, and Mavericks does not need SSE4.1

Date: 2026-09-21
Status: accepted, on measurement

Every `-cpu` line this project has ever used came from one place: a UTM
bundle P1 copied because it booted. `Penryn,+ssse3,+sse4.1,+sse4.2` has
been in every profile, both build scripts and the ledger since, and nobody
had asked which part of it Mavericks actually requires. Every host it ran
on afterwards was newer than the model it names, so the question could not
come up by accident.

It matters because of one machine. `docs/test-hosts.md` names the Mac Pro
1,1 as the most informative second host in the fleet — the only Xeon, and
therefore **the only machine that can settle G14**, the entry that claims
`MacPro5,1` SMBIOS panics on a non-Xeon CPU. That same file then wrote it
off: Woodcrest is 2006, SSE4.1 arrived with Penryn in 2007, so `-cpu
Penryn,+sse4.1` should be rejected outright. Reasoned from CPU
generations, never measured, and it cost the project its only Xeon.

## Decision

**`image/build-image.sh --cpu` takes any QEMU `-cpu` string, and
`lib/cpu.sh` carries a table of the lines this project has evidence for,
each with a status and the evidence behind it.** The table is guidance: an
unlisted line warns and proceeds. The manifest records a `cpuline` row
saying what the table knew about that line when the image was built.

**The default does not change.** It stays
`Penryn,+ssse3,+sse4.1,+sse4.2`.

## The measurement

Primary host (`pet-power-plant`, i7-8700B, QEMU 8.2.2, `-accel kvm`), one
changed `-cpu` line, a qcow2 overlay on the SSH-capable image so the source
was never written, the verify stage's own checks over SSH:

| `-cpu` line | SSH | guest's `machdep.cpu.features` | SHA-256 of 64 MiB of zeros |
|---|---|---|---|
| `Penryn,+ssse3,+sse4.1,+sse4.2` | 20 s | …SSSE3 CX16 **SSE4.1 SSE4.2** | correct |
| `Penryn` | 20 s | …SSSE3 CX16 **SSE4.1** | correct |
| `Conroe` | 20 s | …**SSSE3** | correct |

All three reported `10.9.5 (13F34)`, all three answered SSH in the same
twenty seconds, and all three hashed 64 MiB and got
`3b6a07d0…c421351`, which is the right answer. Nothing panicked, so there
is no panic screenshot to show: the interesting evidence here is the
feature list the guest printed, not the fact that it came up.

### 1. Mavericks does not need SSE4.1

`Conroe` is Conroe/Merom — SSSE3 without SSE4.1, which is the feature set
of the Mac Pro 1,1's 2006 Woodcrest Xeon. The guest booted on it and told
us so itself: no `SSE4.1` in the list it printed. The floor generally cited
for 10.9 is SSSE3, SSE4.1 became a hard macOS requirement much later, and
this is the first time anybody here checked.

So the flag was in the line because the reference configuration happened to
have it, not because the OS wants it. **The Mac Pro 1,1 is viable.**
`docs/host-profile.md` G3 and the Mac Pro entry in `docs/test-hosts.md`
have both been rewritten.

### 2. Two of the three flags are redundant, and the third is not

Bare `Penryn` already reports SSSE3 and SSE4.1: `+ssse3` and `+sse4.1` ask
QEMU for what the model gives anyway. `+sse4.2` does **not** — QEMU's
`Penryn-v1` has no SSE4.2 and should not, because real Penryn had none;
SSE4.2 arrived with Nehalem in 2008. The line asks for a feature the CPU it
names never had.

## Why the default stays over-specified anyway

Because "it is over-specified" is a tidiness argument and the thing on the
other side is evidence. `Penryn,+ssse3,+sse4.1,+sse4.2` is the only line
with a **completed unattended install** behind it — twice, on two hosts,
on QEMUs three major versions apart. `Conroe` and bare `Penryn` have each
booted an image that was *installed* under the default line.

`docs/decisions/0008` is the reason that distinction is not pedantry. A NIC
turned out to be **build-time state** in 10.9: an image installed with one
network device and booted with another enumerates the device, matches the
driver, and has no network service at all. Nothing yet suggests the CPU
model behaves that way — but nothing rules it out, and changing a default
on the strength of a boot test, in a guest that has already surprised us
once in exactly this shape, is how the next inherited-claim entry gets
written about us. So `lib/cpu.sh` has two statuses, `VERIFIED` and
`BOOTED`, and the default sits on the only `VERIFIED` row.

**What would move it:** an unattended install on `Conroe` that reaches SSH.
That is one `--cpu Conroe` run of the full pipeline, and it makes the
lowest row of the ladder the default — which is the right default for a
project whose whole portability story is "older hosts than ours".

## What a host can now answer for itself

`bin/triangulate.sh --probe` runs the `enforce` test across **every row of
the table**, not just the current line: a paused, diskless, displayless VM
per row, a tenth of a second each, nothing written anywhere. The report
prints which lines this host can provide, which it refuses, and — for a
refusal — the feature that was missing.

The Mac Pro 1,1 can answer this in two minutes with nothing installed on
it. That is the point: this turns `docs/test-hosts.md`'s prediction into a
question the hardware settles.

Ledger entry **G25** is the hypothesis ("this host can provide every row"),
and `g25_verdict` in `lib/triangulate.sh` reports on it. It is written and
tested before the hardware exists because G21 sat in the ledger for a full
day with no verdict function, so the run that settled it printed nothing
about it — a hypothesis the harness cannot report on is not being tested by
the harness.

**The primary host REFUTES G25 on day one**, and the reason is worth
recording: `qemu64` is refused because QEMU's own `qemu64` model asks for
`CPUID.80000001H:ECX.svm`, which is AMD's virtualization bit, on an Intel
machine. It has nothing to do with anything 10.9 needs. The report names
the missing feature for exactly this reason — a bare "rejected" invites the
reader to conclude the host is too old, which is the mistake this ADR
exists to undo.

## Note for P5

P5 plans to compare `Haswell-noTSX` and `+invtsc` for performance.
**`Haswell-noTSX` is already a row in `lib/cpu.sh`, at NOT TESTED, naming
P5.** Fill that row in. Do not start a second record of the same question:
the reason this project has an ADR about a `-cpu` line at all is that the
line lived in six profiles and two scripts with no single place saying what
was known about it.

If P5 finds a model that is faster and installs, it moves that row to
VERIFIED and this ADR's default changes — which is the table working as
intended, not a contradiction of it.

## What was not measured

- **No install on anything but the default line.** Three boots, one
  install line. See above for why that gap is the whole reason the default
  did not move.
- **`Nehalem`, `Westmere`, `SandyBridge`, `IvyBridge`, `host`, `qemu64`.**
  Listed, never booted, and the table says so on every row.
- **One QEMU, one host.** Everything above is 8.2.2 on Coffee Lake.
  `squirrel-zapper` has 11.1.1 and can run the same three boots in five
  minutes.
- **TCG.** Every boot used KVM. Under TCG the emulator provides SSE4.1
  whatever the host has, so a TCG run cannot distinguish any of this — which
  is why `bin/triangulate.sh` says CANNOT-SAY for G25 rather than CONFIRM
  when it was not run under a hardware accelerator.

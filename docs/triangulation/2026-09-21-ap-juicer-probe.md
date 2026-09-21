# ap-juicer — Mac Pro 1,1, Debian 13 — probe

2026-09-21. The third host, and the one two ledger entries have been
waiting for: **a Xeon**.

Xeon 5150 (Woodcrest, 2006), 4 cores, 9.9 GiB RAM, Debian 13 trixie,
kernel `7.1.8+deb13-amd64`, QEMU 11.0.2, repo on **ZFS**, images on
**ext2/ext3**.

## The blocker, and it is fixable

```
accel_kvm    no
kvm_note     /dev/kvm exists but is not writable by this user (group membership?)
accel_chosen tcg
```

Not a hardware limitation — a group membership. Until it is fixed every
result here is about TCG, and an install would take hours rather than
minutes. **`sudo usermod -aG kvm $USER`, then log back in.**

It also makes the CPU table worthless on this host, which the report says
itself: under TCG the emulator implements SSE4.1 regardless, so every row
passes and nothing is learned about the hardware. **G25 CANNOT-SAY** for
exactly that reason — a verdict function correctly declining to answer.

## With KVM, the CPU table means something

Second probe, after `usermod -aG kvm`:

```
cpu_line_verdict  rejected
  Conroe                         accepted
  Penryn                         rejected  missing: sse4.1
  Penryn,+ssse3,+sse4.1,+sse4.2  rejected  missing: sse4.1, sse4.2
  Nehalem / Westmere / Sandy / Ivy / Haswell-noTSX   rejected
  host, qemu64                   accepted
```

**The default `-cpu` line is refused on this host**, exactly as
`docs/test-hosts.md` predicted from CPU generations before anyone ran the
machine — and `decisions/0009` had already established the escape hatch by
booting 10.9 on `-cpu Conroe`. The prediction and its remedy were both in
place before the hardware arrived. **G25 REFUTE**, and it names the missing
CPUID leaf per row rather than saying "no".

## One of its four cores is dead

```
CPU(s): 4 · On-line: 0-2 · Off-line: 3
[10.378314] CPU3 failed to report alive state
```

The probe first reported `cpu_cores 4, cpu_logical 3`, which reads as a
parsing bug and is not one: a core did not come up during SMP boot and the
kernel gave up after ten seconds. Hardware, not configuration — a failing
core, a seating problem, or twenty-year-old thermal paste.

Not a blocker: the host works at 75%. But it is a triangulation fact, not
a footnote, because it changes every timing this project ever records
there. The probe now reports `cpu_offline` and says so in its own words
rather than leaving a confusing ratio for someone to misread.

## What it settled anyway

| Entry | Verdict | Why it matters |
|---|---|---|
| **G3** | REFUTE | No SSE4.1, as `docs/test-hosts.md` predicted from CPU generations. **Not a stopper**: `decisions/0009` established that 10.9 boots on `-cpu Conroe`, so this host takes the Conroe row rather than being excluded. The prediction and the escape hatch were both written before the machine was ever run. |
| **G18** | REFUTE | No EPT. Nested virtualization and the VMware Fusion goal of `decisions/0005` are out of reach here whatever CPU model we pick. |
| **G10** | REFUTE | ext2/ext3, no reflinks: golden promotion is a full copy. Budget time and space. |
| **G12** | REFUTE, and it measures the cost directly | **This machine is the NFS server.** `/persistent/code/trees` on local ZFS here is the very export `pet-power-plant` and `squirrel-zapper` mount. So 0.39 ms and 10–15 ms per file create are *the same files*, from the server and from its clients — which makes the penalty attributable to NFS itself rather than to anything about the repository or the storage. The split is unnecessary here because there is no network in the path. |
| **G4** | REFUTE | 4 cores, no SMT. P5's pinning ladder does not transfer. |
| **G14** | CANNOT-SAY | *"this IS a Xeon — the host the entry has been waiting for."* Settling it needs an install with SMBIOS `MacPro5,1`, which `triangulate.sh` deliberately does not do. |

## Two harness bugs, both ours

A third host, a third distribution, and the fact-gathering broke in two
new ways.

**1. A fact printed with no name.**

```
  build_tree_kept        n/a
  yes
```

Built as `[ "$level" = probe ] && echo n/a || { … } && echo yes || echo
no`. On a probe `echo n/a` *succeeds*, so the trailing `&& echo yes` ran
as well and the value became two lines. The SC2015 shape shellcheck flags
elsewhere in this repo — it does not reach inside a command substitution.

**2. A topology that describes no machine.**

```
  cpu_cores 4 · cpu_logical 3 · cpu_threads_per_core 0
```

`cpu_cores` reads the *topology* (`cpu cores` × sockets); `cpu_logical`
counts *online* processors. They are not comparable, so their quotient
can be anything, and integer division turned 3/4 into 0. Now derived from
`/proc/cpuinfo`'s own per-socket `siblings`, and reported as `unknown`
rather than as a number nobody can act on.

Both fixed with regression tests asserting the report contains no bare
value line and no zero threads-per-core.

## A consequence of being the server

`docs/test-hosts.md` warned that this machine "is presumably doing a job
already; disruption there costs more than on a spare machine". That is
sharper than it first read: a build here competes with the NFS service
the other two hosts depend on, including for their own repository
access. Sequence accordingly — do not build here while another host is
triangulating.

## Next here, in order

1. `usermod -aG kvm`, log back in, re-run `--probe`. The CPU table then
   means something.
2. `./bin/triangulate.sh --full --cpu Conroe --keep-build`.
3. **G14**: an install with SMBIOS `MacPro5,1`. This is the only machine
   that can settle whether `AppleTyMCEDriver`'s panic was about the Xeon
   or about something else — and my P1 explanation is what is on trial.

---

# `--full` completes — a 2006 headless Xeon runs the whole pipeline

Eleven stages, all `ok`. A Mavericks guest installed, booted without
installer media, and answered SSH on a machine that is nineteen years
old, has no SSE4.1, no EPT, one dead core, and nobody logged in.

```
esd/opencore/ovmf/payload reused · efi 1s · openssh 0s
media 426s · target 0s · install 1656s · verify 114s · manifest 130s
```

## What it settled

**G26, by measurement.** An hour earlier this host failed at
`NotAuthorizedCanObtain` — udisks2 refusing loop-setup to a session with
no seat. The media stage now assembles HFS+ inside the privops microVM
and asks udisks2 for nothing, so it built 6.4 GB over SSH to a headless
server. **That also unblocks P6**, whose CI runners are headless by
definition and would have hit this later with less context.

**`Conroe` promoted BOOTED → VERIFIED.** `pet-power-plant` had only
*booted* an image installed under the default line; this is the first
completed **install** on the row. The distinction exists because ADR 0008
showed a guest installed with one NIC will not work under another —
booting and installing are different claims about the same string.

**G13 and G16 on a third QEMU.** EHCI+UHCI carried a full install under
QEMU 11.0.2; the guest reports connection bus `SATA`. Both findings now
hold across 8.2.2, 11.0.2 and 11.1.1.

**G21 refuted a second time**, independently: `ignore_msrs=N` here too,
and the install completed.

## Timings, against the other two hosts

| stage | pet-power-plant (6c, 2018) | squirrel-zapper (2c, 2015) | ap-juicer (3c of 4, 2006, no EPT) |
|---|---|---|---|
| media | 113 s | 118 s | **426 s** |
| install | 780–817 s | 1332 s | **1656 s** |

Install is 2.1x the primary. Less than feared: no EPT means shadow
paging, and the machine is from 2006. P6 should budget from this ratio
rather than from a modern desktop's.

## A verdict that asserted a falsehood

The run printed:

> G26 CONFIRM — udisks2 granted loop-setup here, so this host does have
> whatever polkit wants — usually an active local session

**udisks2 was never asked.** `g26_verdict` keyed on `media_built=yes`,
which was a true test while the media build used udisks2 and became a lie
the moment it stopped — on the very host whose refusal prompted the fix.

Corrected. Worth stating as a rule: **a verdict function has to be
reviewed when the thing it judges changes**, because a stale one does not
fall silent, it keeps answering confidently. The ledger is where this
project keeps what it believes, and a false CONFIRM is worse than a
missing row.

## Still open here

**G14** — the reason this host was wanted. It needs an install with
SMBIOS `MacPro5,1`, which `triangulate.sh` deliberately does not do. My
P1 explanation of the `AppleTyMCEDriver` panic is what is on trial, and
this is the only Xeon available to try it.

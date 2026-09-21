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

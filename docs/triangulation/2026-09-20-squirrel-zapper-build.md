# squirrel-zapper — `--build` completes — 2026-09-20

The first time the boot stack and installer media have been built anywhere
but the primary host. Eight stages, all `ok`:

```
esd 256s · opencore 395s · ovmf 228s · efi 2s
openssh 2s · payload 0s · media 115s · target 0s
```

Host: 2015 MacBook Air 11", EndeavourOS, kernel `7.2.6-arch2-1`,
**gcc 16.2.1**, **QEMU 11.1.1**, 2 physical cores, 7.8 GiB RAM.
Primary host for comparison: Linux Mint 22.3, gcc 13.3.0, QEMU 8.2.2,
6 physical cores, 62 GiB.

## The result that matters: G20 CONFIRM

Media built here **and verified against `media/apple-packages.sha256`
from a fresh mount**. That verification — the one written after three
corrupt builds in six on the primary host — had never run on another
machine. It ran and passed.

## G5: the substance is answered, the verdict is still CANNOT-SAY

Both checksums now exist from two hosts, and the interesting part is that
they disagree:

| Artifact | Primary (gcc 13.3.0) | squirrel-zapper (gcc 16.2.1) |
|---|---|---|
| `OVMF_CODE.fd` | `195c4dcf…` | `e3d0c6f5…` |
| OpenCore EFI image | varies per run | varies per run |

**The firmware is reproducible per toolchain, not across toolchains.**
Same pinned sources, same audk commit, same `-std=gnu17`, different
compiler, different bytes. That is not a defect — it is what pinning
sources and not pinning a compiler means, and `decisions/0004` already
says so under "The compiler is not pinned". This run turns that from a
stated risk into a measured fact.

**The OpenCore row cannot test anything and should stop pretending to.**
Its value differed between two runs *on this same host with the same
compiler* (`31858701…`, `ae6616ab…`, `badddb58…`), because `mformat`
stamps a volume serial into the FAT image. Comparing it across hosts is
meaningless. The OVMF value is the one worth diffing.

## What it took to get here

Four host assumptions in `lib/privops-qemu-linux.sh` were wrong, each
found only by running somewhere new, and each silent until the run that
added diagnostics:

| Assumption | Reality on Arch |
|---|---|
| kernel at `/boot/vmlinuz-$(uname -r)` | `/lib/modules/<rel>/vmlinuz` |
| modules are uncompressed `.ko` | `.ko.zst` |
| `busybox` on `$PATH` is static | true here, but by luck of packaging |
| `hfsplus.ko` needs nothing loaded first | needs `cdrom` |

Plus two failures that were ours rather than the host's: a microVM
console captured with `out=$(...)` that yielded zero bytes under
`-nographic`, and a `timeout` in an assignment that `set -e` turned into
a silent exit.

Seven runs on someone else's laptop, five of them spent on missing
evidence rather than on the actual defects. `bin/privops-selftest.sh`
now answers in ten seconds what the pipeline answers in twenty minutes,
and should have existed before the first remote run.

## Still CANNOT-SAY here

G13, G14, G16 need a booted guest or a Xeon; G19 needs the deliberate
two-install experiment. `--full` on this host would settle the first
three — and would also test **G21**, since this machine runs with
`kvm.ignore_msrs=N`.

---

# `--full` completes — 2026-09-21

Eleven stages, all `ok`. A Mavericks guest installed, booted without
installer media, and answered SSH on a second machine.

```
esd 216s · opencore 393s · ovmf 229s · efi 2s · openssh 1s · payload 1s
media 118s · target 0s · install 1332s · verify 113s · manifest 99s
```

**Install: 1332 s against 780–817 s on the primary host.** 1.7x, for a
2-core Broadwell against a 6-core Coffee Lake. P6 should budget from the
ratio rather than from our own wall clock, and TCG will make it worse.

## G21 REFUTED — the sudo step we never needed

`kvm.ignore_msrs=1` was applied on the primary host on 2026-09-17 because
Somlo and OSX-KVM both call for it, and was **never tested without**.
`squirrel-zapper` runs with `ignore_msrs=N` and installed, verified and
answered SSH regardless.

Scope of the refutation: this CPU (Broadwell) and QEMU 11.1.1. That is
enough to stop *requiring* it.

Two things made this nearly invisible twice over:

1. It lived in §3 of `host-profile.md` as a **host state change** rather
   than in §4 as a **hypothesis**, so for two phases nothing tried to
   falsify it. The ledger is where assumptions go to be tested; this one
   was not in the ledger.
2. Once it was added as G21, `bin/triangulate.sh` had **no verdict
   function for it** — so the run that settled it printed nothing about
   it. The refutation came from reading `kvm_ignore_msrs N` in the facts
   block next to a successful install, by hand. A hypothesis the harness
   cannot report on is not being tested by the harness. `g21_verdict`
   now exists.

## Also confirmed by a booted guest

| Entry | Verdict | What it now rests on |
|---|---|---|
| **G13** | CONFIRM | EHCI+UHCI carried a full install and SSH **under QEMU 11.1.1** — the finding survives three major QEMU versions, which the original entry could not know |
| **G16** | CONFIRM | the guest reports connection bus `SATA` for `ide-hd` on q35, on a different QEMU |
| G17, G18, G20 | CONFIRM | as in the `--build` run |

## Still open here

**G14** needs a Xeon — the Mac Pro 1,1. **G19** needs the deliberate
two-install experiment, which this script deliberately never performs
because the entry's own standing advice is one build per host.

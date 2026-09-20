# squirrel-zapper — 2015 MacBook Air 11", EndeavourOS — probe

Run 2026-09-20T00:28:22Z, `./bin/triangulate.sh` at level `probe`.
The second host this project has ever run on.

## Against the primary

| | Mac mini 2018 (primary) | squirrel-zapper |
|---|---|---|
| CPU | i7-8700B, 6C/12T | i7-5650U, **2C/4T** |
| RAM | 64151 MiB | **7835 MiB** |
| QEMU | 8.2.2 | **11.1.1** |
| Kernel | `7.2.6-1-t2-noble` | **`7.2.6-arch2-1`**, unpatched |
| `kvm.ignore_msrs` | **Y** | **N** |
| Missing tools | none | **6** |
| `-cpu` line | accepted | accepted |
| btrfs, reflink, `chattr +C` | yes | yes |
| repo on NFS | yes, 10.12 ms/create | yes, 9.27 ms/create |

## Verdicts

**REFUTED: G4, G6, G7.** **CONFIRMED: G1, G2, G3, G8–G12, G17, G18.**
**CANNOT-SAY: G5, G13, G14, G16, G19, G20** — all need either a Xeon or a
booted guest.

## What the refutations cost, and what they saved

**G4** is the one that justifies triangulating before tuning. P5 plans to
compare "vCPU counts of 2, 4, and 6 — six physical cores are available —
pinned to physical cores rather than SMT siblings". This host has two
physical cores, so that experiment cannot run here in the form it is
written. Had P5 gone first, a six-core answer would have entered the
recommended default profile as a fact. P5 now has to express its vCPU
choice as a rule derived from topology.

**G6** turns a caveat into a test. Every device-behaviour finding here was
learned on QEMU 8.2.2 — G13's EHCI/UHCI requirement most of all, which is
the reason the guest boots at all. 11.1.1 is three major versions on, with
three years of changes to USB, AHCI and slirp, and it accepts the same
`-cpu` line. A `--full` run here is the cheapest available test of whether
those findings were about 10.9 or about one QEMU.

**G7** separates two variables that were confounded. The primary host is
Apple hardware *and* runs a T2-patched kernel, so nothing could tell those
apart. This host is Apple hardware with a stock kernel. Anything that
differs is now attributable.

## The gap this run found in the ledger itself

`kvm.ignore_msrs=1` was set on the primary host on 2026-09-17, on the
authority of Somlo and OSX-KVM, and **never tested without**. It was
recorded in §3 of `host-profile.md` as a host state change rather than in
§4 as a hypothesis — so for two phases nobody tried to falsify it, because
the ledger is where things go to be falsified and it was not in the ledger.

It is now **G21**, and this host settles it for free: `ignore_msrs` is `N`
here. A `--full` run either succeeds, and we stop asking users to poke a
kernel parameter, or fails informatively.

## A caution about the CONFIRMs

G10, G11 and G12 confirmed — btrfs, reflinks, an NFS-mounted repo. Both
machines are administered by the same person with the same storage
conventions, so this is closer to "consistent setup" than to "portable
finding". A host built by someone else would test them properly. Recorded
as confirmations, but weak ones.

## Missing tools

`dmg2img`, `kpartx`, `sgdisk`, `mkfs.hfsplus`, `nasm`, `iasl` — exactly
the prediction in `docs/test-hosts.md`, that `boot/prereqs.sh` names Debian
packages. The probe reports tools rather than packages and prints no
install command, deliberately: mapping them is the project's debt, not the
user's, and `prereqs.sh` is where the mapping belongs.

Package manager present: `pacman`.

## Next on this host

`--build`, once the six tools are there. That settles **G5** — whether
`boot/build-ovmf.sh` and `boot/build-opencore.sh` reproduce the same
checksums on a different distribution and toolchain — which is a stronger
claim than the one G5 originally made, and the strongest test available
short of an install.

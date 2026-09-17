# 0003 — VM images and the Tier 2 quarantine live on local btrfs, not in the repository

Date: 2026-09-17
Status: accepted

## Context

The plan originally defaulted `GOLDEN_DIR` to `<repo>/golden` and `WORK_DIR`
to `<repo>/work`. That was written on the assumption that the repository sits
on the host's local NVMe.

It does not. `~/Documents/trees` is an NFSv3 mount from `ap-juicer`
(192.168.1.224), while `/` and `/home` are btrfs on the local NVMe. The
assumption was discovered to be wrong while implementing Task 3, when a
subagent noticed `mktemp` and the repo were on different filesystems.

Measured on this host: NFS bulk transfer runs at 60 MB/s versus 567 MB/s
local — a real but survivable 9.4x gap. File creation is the killer: 18 ms
per file over NFS versus 0.06 ms local, a 156x difference driven by
per-operation round trips rather than bandwidth. Metadata-heavy work is where
NFS actually hurts.

## Decision

Disk images live under `${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}`,
on local btrfs. `GOLDEN_DIR` and `WORK_DIR` default to `$MQG_IMAGE_DIR/golden`
and `$MQG_IMAGE_DIR/work`. The repository holds code, docs and the lab log;
never images.

This extends to the Tier 2 quarantine (see the provenance-tier rule in
`docs/superpowers/specs/2026-09-17-mavericks-guest-design.md`). It used to
live in-repo at `vendor/reference/`, but one of its contents,
`EFI-LEGACY.img`, is a 191 MiB OpenCore image that QEMU reads on every single
boot from Task 12 onward, and the performance phase boots dozens of times.
Reading a file that size over NFS on every boot is exactly the avoidable cost
this decision already exists to eliminate for disk images, so the quarantine
moved out too: `MQG_VENDOR_DIR` defaults to
`$MQG_IMAGE_DIR/vendor-reference`, alongside `golden/` and `work/`. Profiles
reach it with the `%VENDOR%` token in `lib/profile.sh`, exactly parallel to
`%REPO%` and `%IMAGES%`. `vendor/sources.tsv` — a small tracked text file,
not a blob — stays in the repository; only the fetched artifacts it pins
move.

## Reasoning

- **Correctness.** A running guest's qcow2 over NFSv3 risks file-locking
  problems. This is not a performance preference; it is a way to lose a disk
  image.
- **Speed.** Every P5 experiment boots a clone. Guest disk I/O over a 1 Gb
  network link would dominate every measurement, making the tuning phase
  measure the network rather than the change under test.
- **Reflinks.** `golden_promote` uses `cp --reflink=auto`. On btrfs a 60 GB
  promotion is near-instant and consumes almost no additional space. Over NFS
  the flag silently degrades to a full copy — the same command, quietly
  hundreds of times slower.
- **The repo stays clonable.** Code and notes remain on NFS where the user's
  other 300+ repositories live, and the repo does not become unclonable
  because someone committed a 60 GB file.

## Consequences

- `image/`, `vm/golden.sh` and `vm/clone.sh` honour `MQG_IMAGE_DIR`.
- `vm/run.sh` and `bin/tier-check.sh` honour `MQG_VENDOR_DIR`, defaulting to
  `$MQG_IMAGE_DIR/vendor-reference`.
- The image directory gets `chattr +C` on creation, because btrfs
  copy-on-write fragments qcow2 files badly. This must be set on the
  directory *before* any image is written; applying it to an existing file
  does nothing. The same applies to the vendor directory, since it holds
  qcow2-wrapped firmware images.
- `.gitignore`'s `golden/` and `work/` entries stay as belt-and-braces, in
  case someone overrides the location back into the repo. There is no longer
  a `vendor/reference/` entry to keep for the same reason: the quarantine
  directory doesn't exist in the repo at all now, so there is nothing for
  `.gitignore` to belt-and-brace.
- `bin/tier-check.sh`'s gate now greps expanded profiles for the resolved
  `$MQG_VENDOR_DIR` path rather than the textual convention
  `vendor/reference/`. This is a strictly stronger check: it matches the
  real configured location instead of one particular spelling of it.
- Local free space (1.7 TB) rather than NFS free space (3.9 TB) is the
  binding budget. Still ample.

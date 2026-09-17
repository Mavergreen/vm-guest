# 0003 — VM images live on local btrfs, not in the repository

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

## Decision

Disk images live under `${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}`,
on local btrfs. `GOLDEN_DIR` and `WORK_DIR` default to `$MQG_IMAGE_DIR/golden`
and `$MQG_IMAGE_DIR/work`. The repository holds code, docs and the lab log;
never images.

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
- The image directory gets `chattr +C` on creation, because btrfs
  copy-on-write fragments qcow2 files badly. This must be set on the
  directory *before* any image is written; applying it to an existing file
  does nothing.
- `.gitignore`'s `golden/` and `work/` entries stay as belt-and-braces, in
  case someone overrides the location back into the repo.
- Local free space (1.7 TB) rather than NFS free space (3.9 TB) is the
  binding budget. Still ample.

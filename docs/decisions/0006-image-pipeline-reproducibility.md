# 0006 — What "reproducible" means for the image pipeline

Date: 2026-09-17
Status: accepted — this is P4's exit artifact

## Context

P4's exit criterion is **one command, from a clean checkout, to a bootable,
SSH-reachable image, with no human interaction — run twice, outputs
equivalent.**

"Equivalent" is the word doing the work, and it is the one most likely to
be read as something it does not mean. This document says precisely what
is claimed, what is not, and how each is checked, so that "reproducible"
is a property someone can test rather than a word in a README.

The method itself lives in `image/compare-images.sh`, which prints it with
`--describe`. An unstated comparison method is not reproducible either.

## The claim

**Same inputs produce an image that behaves identically. Not an image that
is byte-identical.**

The second is not merely unachieved here; it is not achievable, and it is
not worth achieving. An OS X install writes:

- **Timestamps** on essentially every installed file, from the clock at
  install time.
- **A volume UUID** (`diskutil info`'s Volume UUID), generated when
  `diskutil partitionDisk` creates the filesystem.
- **A machine UUID and a hardware serial** derived at first boot.
- **Caches** — `dyld`'s shared cache, the kernel cache, icon and font
  caches — built at first boot from whatever order things happened to
  load in.
- **Spotlight and FSEvents indexes**, whose contents depend on when the
  indexer ran relative to everything else.
- **Random seeds**, `/private/var/db/uuidtext`, SSH host keys.

And the qcow2 container adds one more layer: a sparse image records the
*order* blocks were allocated in, so two runs of an identical install
differ in the file even where the filesystem contents do not.

Chasing byte-identity would mean patching all of that out of an operating
system we do not control and must not modify, for a property nobody here
needs. What P4 needs is that a rebuilt image is the same image in every
way a user or a measurement can tell.

## What is pinned

Every input is recorded in `<name>.manifest`, written by
`image/build-image.sh`:

| Field | What it pins |
|---|---|
| `esd` | sha256 of Apple's `InstallESD.dmg`. The OS comes from Apple only. |
| `media` | sha256 of the installer media built from it on Linux |
| `opencore` | sha256 of the OpenCore EFI image, built from pinned source |
| `ovmf` | sha256 of the guest firmware, built from the same pinned tree |
| `config` | sha256 of `boot/config/config.plist` |
| `payload` | sha256 of the first-boot payload package |
| `sshkey` | fingerprint of the public key authorized in the image |
| `updates` | which post-10.9.5 updates the image carries |
| `accel` | accelerator, machine type, CPU model, memory, disk size |
| `qemu` | the QEMU that ran the install |
| `commit` | the git commit built from, and whether the tree was dirty |

Two builds claiming to be the same must list the same values for all of
these. `image/compare-images.sh` checks that first, because if the inputs
differ, nothing downstream is evidence of anything.

## What varies, and why each is acceptable

| Varies | Why it is not a defect |
|---|---|
| `name`, `built`, `image` in the manifest | The build's own identity, its clock, and the checksum of the output. By construction these differ. |
| File **timestamps** | Written from the clock during the install. The comparison uses paths and sizes, not mtimes. |
| Volume, machine and hardware UUIDs | Generated per install. An image that reused them would be the defect. |
| `/private/var`, `/var` | Logs, receipts, the ASL store, caches, `uuidtext`. Written continuously by a running system; two boots of the *same* image differ here. |
| `/Users` | The home directory is created at first boot from a template, and a login writes to it immediately. |
| `/System/Library/Caches`, `/Library/Caches` | Built at first boot. |
| `/.Spotlight-V100`, `/.fseventsd` | Indexes, whose contents depend on when the indexer ran. |
| SSH **host** keys | Generated on first launch of sshd. Under `/private/var`, and deliberately so: a shipped host key would be a shared secret. |
| qcow2 block allocation order | A property of the container, not of the filesystem. |

Everything outside those prefixes must match exactly — same paths, same
sizes. That is the substantive claim, and it covers the entire installed
operating system.

## How it is checked

`image/compare-images.sh <a> <b>` performs four checks and reports each
separately, so a failure names which one:

1. **Inputs.** Every manifest field but `name`, `built` and `image` must
   be identical.
2. **Boot and SSH.** Each image is booted headless, with **no installer
   media attached**, and must answer SSH within the timeout using the key
   it was built for. This is why the comparison boots the images instead
   of reading them offline: "boots unattended" and "accepts the key" are
   two of the four things being claimed, and no offline file listing can
   test either.
3. **Identity.** `sw_vers`, `hw.model`, `hw.ncpu`, `hw.memsize`, the
   account's uid/gid/group membership, Remote Login, sleep settings,
   auto-login, `.AppleSetupDone`, and — importantly — that the first-boot
   LaunchDaemon has **removed itself**.
4. **File sets.** Every regular file on the boot volume as `<size>
   <path>`, sorted, with the prefixes above excluded. Collected in the
   guest with `find / -xdev -type f -exec stat -f '%z %N' {} +`.

The inventory is taken as the guest account rather than as root, so a
small number of root-only paths are unreadable. The count of unreadable
paths is reported rather than assumed away; all of them fall under
excluded prefixes.

## The stronger test: a fresh clone

Running the pipeline twice in one working copy proves less than it looks
like it proves. It cannot distinguish "the repository carries everything
needed" from "this working copy accumulated something over the session".

So the exit test is a **`git clone` into a new directory with a fresh
`MQG_IMAGE_DIR`**, and a build from there. What that finds is not usually
a bug in the pipeline; it is an input that was never committed. Results
are in `NOTES.md`.

## Consequences

- **P5 can take a baseline it can recreate.** A measurement against an
  image nobody can rebuild is a measurement of one afternoon.
- **P6 reuses this pipeline with `--accel tcg`** rather than a second one.
  The manifest records the accelerator, so a CI image and a local image
  are distinguishable by their manifests rather than by memory.
- **`--updates` exists with one value implemented.** `docs/open-questions.md`
  Q1 asks whether images should carry Apple's post-10.9.5 updates and names
  P4 as its deadline. This decision does not answer it. What it does is
  keep it answerable: the switch, the manifest field, and the
  `OSInstall.collection` mechanism the answer would use are all in place,
  so answering it later is configuration rather than a rewrite.
- **Byte-identity stays out of scope.** If it is ever wanted, the place to
  start is a deterministic clock for the guest and a post-pass that
  normalizes UUIDs — both of which would change what the image *is*, and
  so would need their own decision.

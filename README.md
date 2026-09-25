# vm-guest

Run **OS X 10.9 Mavericks** in a virtual machine, built unattended from
Apple's own installer -- nobody has to sit and watch it. `vmavs` is the one
command that does it.

```sh
vmavs doctor            # can this machine do it?
vmavs image --describe  # show the plan; touches nothing
vmavs image             # build it, from Apple's installer, unattended
```

That takes roughly 15-20 minutes once the boot stack is already built --
longer on a cold checkout, which also compiles OpenCore and OVMF from
source and waits on a download from Apple. The image lands at
`~/.local/share/mavericks-qemu-guest/images/` as a qcow2, with a manifest
beside it naming every input that went into it. The target disk is 60 GB,
but sparse: a finished install has measured at under 11 GiB actually
written.

**No shipped command boots the image `vmavs image` builds, yet.**
`decisions/0007` says `vmavs run` should boot a throwaway clone of it;
today the shipped `run` only boots this project's own named development
profiles, and none of them points at that image. That is the open gap.
(The in-progress Go `vmavs`, below, does boot it; it is not the shipped
path yet.)

`p4-linuxmedia`, a development profile from the P4 phase, is shown below
for developers only. It is not a next step after `vmavs image`: it boots a
development disk with installer media attached, and nothing in the shipped
path creates the files it needs, so on a fresh host it fails.

```sh
# developer profile; needs work/p4-target.qcow2 and
# work/p4-linuxmedia-VARS.fd from earlier phases
vmavs run p4-linuxmedia
vmavs ssh --port 2223     # it forwards SSH to 2223, not the default 2222
```

## Two rules this project does not bend

- **The operating system comes from Apple, and only from Apple.** Firmware
  and bootloaders may be third-party; macOS disk images may not. No
  prebuilt third-party macOS image is used, ever.
- **Never publish the guest image or a snapshot.** Not as a release asset,
  not as a package, not anywhere reachable without authentication. `vmavs`
  ships a recipe; you build your own image on your own machine, from
  Apple's bytes, which never enter this repository. `bin/no-apple-bytes.sh` is the
  gate that keeps that true rather than merely intended -- it checks what
  a release would actually contain, not just what anyone meant to commit.

Every host this has actually run on is Apple hardware, which is the case
Apple's own EULA contemplates: virtualizing OS X on an Apple-branded
machine. A non-Apple host is outside that license -- a legal constraint,
not a technical one -- and is also, so far, untested.

## The Go vmavs (in progress)

A Go rewrite of `vmavs` is underway, one subcommand at a time
(`docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md`). Build it with:

```sh
go build -o out/vmavs ./cmd/vmavs
```

So far it has `fetch`, `run`, `ssh`, `emit packer`, `doctor` and `version`
-- the subcommands that fetch and verify Apple's installer, its
post-10.9.5 updates and the guest's OpenSSH, boot a guest, reach it over
SSH and report on the host, not the ones that build an image. `fetch`
adopts the shell tree's own downloads (verified, never moved or deleted)
when they are already there, so switching to the Go binary does not mean
downloading Apple's 5 GB installer again. Point it at an image the shell
pipeline already built:

```sh
export VMAVS_HOME="$HOME/.local/share/mavericks-qemu-guest"
out/vmavs run --image mavericks-20260922 &
out/vmavs ssh -- sw_vers
```

MEASURED on this project's own KVM host, 2026-09-25: both a modern image
and one running Apple's legacy OpenSSH 6.2 boot and answer SSH this way --
see NOTES.md, "P8 -- the Go vmavs boots a built image and answers SSH".

Everything else -- `media`, `install`, `image` and the whole build
pipeline -- is still `bin/vmavs`, unchanged, and stays the shipped path
until phase 6 of the Go design
(`docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md#9-phases`), when
the shell tree is re-measured against the Go one and retired.

## Will it work on my machine?

`vmavs doctor` answers per subcommand: a host with QEMU and no
`mkfs.hfsplus`, say, is READY for `run` and BLOCKED for `media`. Measured so
far: **Linux with KVM, on Apple hardware, works end to end** -- a 2018 Mac
mini, a 2015 MacBook Air and a 2006 Mac Pro have each built and booted a
guest. **macOS and NetBSD have never been tried**; `decisions/0007` names
them as targets. `docs/test-hosts.md` tracks what has actually been run
where, and `vmavs triangulate --probe` writes the same kind of report
about a machine that isn't in that table yet.

## What you get, and what you don't

Today's shipped path is a **headless guest reached over SSH** -- there is
no shipped profile that opens a window. `vmavs install`'s unattended
pipeline creates your account and authorizes your SSH key on first boot;
from there, networking, DNS and SSH all work with no configuration.

A graphical desktop has been reached in this project's own manual testing
(`docs/install-log.md`), including absolute mouse positioning that needs
no third-party kext, contrary to what older prior art claims -- but that
testing used a profile that is now archived, and the headless profiles
this project ships and tests against today don't exercise a display at
all. Sound is off by default; resolution is fixed. None of that is
re-verified by `vmavs image`'s own `verify` stage, which checks that the
guest answers SSH and identifies itself correctly, not what a screen looks
like.

## Commands

| | |
|---|---|
| `vmavs doctor` | What this host can do, subcommand by subcommand |
| `vmavs fetch` | Fetch one pinned input: Apple's installer, OpenSSH, updates |
| `vmavs boot-stack` | Build OpenCore, the guest firmware and the EFI image from pinned source |
| `vmavs media` | Build bootable installer media from Apple's InstallESD.dmg |
| `vmavs install` | Create the target disk and let Apple's installer run, unattended |
| `vmavs clone` | Make a throwaway overlay on a golden image |
| `vmavs run` | Boot a profile |
| `vmavs ssh` | Open a shell in a running guest |
| `vmavs emit` | Write an interop artifact for another tool (today: packer) |
| `vmavs image` | The whole chain: fetch, build, install, verify, record |

`vmavs help` also lists a second tier -- `triangulate`, `golden`,
`compare`, `freshness`, `staleness` -- for probing a new host and managing
images once you have more than one. Every subcommand takes `--help`.

## Installing

Not yet packaged. Clone the repository and put `bin/vmavs` on your `PATH`;
everything else is found relative to it, including through a symlink. The
packaging question is deliberately open -- see
`docs/superpowers/plans/2026-09-22-shipping-vmavs.md`, Phase C.

## Where things are

| Path | What |
|---|---|
| `docs/superpowers/specs/` | Design documents. Start with the umbrella design. |
| `docs/superpowers/plans/` | Implementation plans. |
| `docs/decisions/` | Decision records: what we chose, the evidence, what we rejected. |
| `docs/configuration-register.md` | Every knob, and whether it was measured, inherited or reasoned. |
| `docs/prior-art.md` | Every source worth reading, and what each one gives us. |
| `docs/host-profile.md` | What this host is, and every host-specific assumption we've made. |
| `docs/test-hosts.md` | Which machine can settle which open question. |
| `NOTES.md` | The lab log. Every attempt, including the ones that failed. |

## Ground rules

- **No unreproducible blobs in the shipped boot path.** Everything is Tier 0
  (built from pinned source) or Tier 1 (vanilla upstream, pinned and
  checksummed). Tier 2 blobs live under `$MQG_VENDOR_DIR` (local disk, not
  the repo -- see `docs/decisions/0003-vm-images-on-local-btrfs.md`) and are
  de-risking scaffolding only. `bin/tier-check.sh --strict` enforces this on
  every test run.
- **Write down the failures.** `NOTES.md` is append-only.

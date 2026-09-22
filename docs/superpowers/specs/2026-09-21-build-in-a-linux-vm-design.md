# Design: move the build into a controlled Linux VM

Date: 2026-09-21
Status: proposed — the direction is the user's and is approved. Nothing here
is built, nothing is fetched, and no implementation plan exists yet.
Reopens: `docs/decisions/0004`, option **(c)** ("build with a pinned
toolchain"), which was deferred rather than refused.

The user's words, 2026-09-21:

> "Sounds like it'd be great to do everything but the install in an Alpine
> VM or something, and would win an easy path to other hosts doing the build
> as well."

The observation that prompted it: the user had assumed the build already ran
in a Linux VM we control. It does not. Only the HFS+ privileged operations
do, and only since 2026-09-21.

## 0. How to read the claims in this document

This project has four times caught itself repeating an inherited claim nobody
had checked — the usb-tablet kext, "DNS needs configuration", security update
2016-001 vs 2016-004, and the Mac Pro 1,1's CPU string that cost us the
machine for a year. So every claim below is labelled:

| Label | Means |
|---|---|
| **measured** | A number or an observation from a named host on a named date, with the file it is recorded in |
| **inherited** | Someone else's claim, with its source named. Not yet checked here |
| **reasoned** | Follows from something measured, but nobody has run the thing being claimed |
| **untested** | Nobody has tried. **Not** the same as "known to fail" |

Unlabelled sentences are design intent, not findings.

## 1. What runs where today

Reconstructed from the scripts on 2026-09-21 at `c943433`, not from memory.
`image/build-image.sh`'s `STAGES` list is the pipeline; each row names the
script it actually invokes.

| Stage | Where it runs today | What it needs there |
|---|---|---|
| `esd` | **host** | `media/fetch-installesd.sh`: `curl`, `openssl`, `xxd`, `awk`, `od`, `tr`, `sha256sum`. A fetch and a checksum — no `dmg2img` here |
| `opencore` | **host** | `boot/build-opencore.sh`: `gcc`, `make`, `git`, `python3`, `nasm`, `iasl`, `zip`, and the header `uuid/uuid.h` |
| `ovmf` | **host** | `boot/build-ovmf.sh`: the same EDK II tree and the same toolchain |
| `efi` | **host** | `boot/build-efi-image.sh`: `sgdisk`, `mformat`, `mmd`, `mcopy`, `mdir`, `truncate` |
| `openssh` | **host** | `image/fetch-openssh.sh`: `curl`, `unzip` |
| `payload` | **host** | `image/payload/build-firstboot-pkg.sh`: `python3` (`mkflatpkg.py` writes the xar itself), `sha256sum` |
| `media` | **split** | `media/build-installer-img.sh` runs `dmg2img` **on the host** (twice: the ESD, then `BaseSystem.dmg` from inside it) and then hands the HFS+ assembly, the ownership pass, the package verification and the content digest to the **privops microVM** |
| `target` | **host** | `qemu-img create`, `boot/make-nvram.sh` |
| `install` | **host** | QEMU boots the media and installs 10.9 under the host's accelerator |
| `verify` | **host** | `ssh` to the running guest |
| `manifest` | **host** | checksums of everything above |

**Correction to the table this spec was commissioned from** (measured): the
`media` row is not "microVM already". It is half and half. `dmg2img` — five
gigabytes of it, about 100 s on the primary host (`NOTES.md:2766`) — is host
work inside a stage whose second half is VM work. The microVM's data path is
`ro:<img>` / `raw:<img>`, source images attached as further virtio disks, and
**nothing is copied in or out** (`lib/privops.sh`).

The host tool list is **36 executables plus one development header**
(`boot/prereqs.sh`, counted 2026-09-21), against **20 names** in
`bin/triangulate.sh`'s two lists. `tests/boot_scripts.bats` asserts the two
agree.

## 2. Why this is worth doing

Three arguments, each with its evidence and each with its limit.

### 2.1 Portability — the strongest, and it is measured

**41 GNU-only lines outside `tests/`** (measured, 2026-09-21; the brief's
figure of 43 counted slightly differently, and the difference is not
material): `stat -c` ×24 across twelve files, `truncate` ×12 across five,
`cp --reflink` ×3 of which one is a comment, `find -printf` ×2 (both in
`lib/efi.sh`). Plus 36 tools and a header.

The bring-up cost is measured, and it is the real argument. Across the
triangulation runs recorded in `docs/triangulation/` and the salvaged log
directories in the repository root, **every one of these stopped a run on a
host that was otherwise fine**:

| Failure | Host, date | Recorded at |
|---|---|---|
| `missing required command: zip` at `opencore`, 23 s in | `ap-juicer`, 2026-09-21 | `triangulate-logs-ap-juicer-20260921-144046/`; `boot/prereqs.sh:50` |
| `fatal error: uuid/uuid.h: No such file or directory` in BaseTools, 92 s in — past every `command -v` check, because a header is not an executable | `ap-juicer`, 2026-09-21 | `…-20260921-155041/`; `boot/prereqs.sh:153` |
| `udisks2` refusing `loop-setup` — `NotAuthorizedCanObtain`, i.e. polkit would allow it *after an interactive prompt*, which is no use unattended — 43 s into `media`, after 787 s of successful compiling | `ap-juicer`, 2026-09-21 | `…-20260921-164808/`; ledger **G26** |
| Kernel not at `/boot/vmlinuz-$(uname -r)` | `squirrel-zapper`, 2026-09-20 | ledger **G23** |
| Modules are `.ko.zst`, not `.ko` | `squirrel-zapper`, 2026-09-20 | `lib/privops-qemu-linux.sh:190` |
| `hfsplus.ko` needs `cdrom` loaded first — surfaced as `unknown symbol in module or invalid parameter`, and before the diagnostics went in, as nothing at all | `squirrel-zapper`, 2026-09-20 | `lib/privops-qemu-linux.sh:195` |
| A C23-default compiler breaking `libDER_config.h`, then a GCC 16 warning breaking `MdeModulePkg` | `squirrel-zapper`, 2026-09-20 | ledger **G22**, `decisions/0004` |

**One correction to the brief, and it matters** (measured): the
dynamically-linked busybox is **not** in that list. It has never been
observed on any host. It is a hazard someone reasoned about and guarded
against before it bit — `NOTES.md:4729`, "a dynamic busybox passes
`command -v`, copies fine, produces a well-formed cpio archive, and then
panics on exec inside the microVM with nothing pointing at busybox" — and the
guard is tested with a stand-in binary, not with a real dynamic busybox
(`NOTES.md:4797`). It is the trap the brief says Alpine's static busybox
would avoid. Nobody has fallen into it. Keeping that straight matters
because it is one of the two stated reasons for choosing Alpine, and it is
a reasoned reason, not a measured one.

Also measured, and also a correction to the count: what the repository
records for `ap-juicer` on 2026-09-21 is a `--probe` blocked by `/dev/kvm`
not being writable by that user, **four** salvaged log directories, one
successful complete `--full` that left no directory, and the deliberate
`MacPro5,1` experiment that ran 5496 s and panicked. **The host-tooling bill
was three runs** — `zip`, `uuid/uuid.h`, `udisks` — not seven. Three is
still three runs too many, and it is still the argument; it is just not
seven.

### 2.2 The compiler, which is the one audit unknown this actually fixes

`decisions/0004` is explicit that Tier 0 is currently **"built from pinned
source by an unpinned compiler, in a stated dialect"**, and names option
**(c)** — a container or a bootstrapped GCC — as "the right answer *if these
images ever have to be independently verifiable*". It was deferred, not
refused: *"(c) stays available."* A build VM is (c).

**Pushback on the brief, with evidence.** The brief says the audit's three
costliest unknowns are all build-environment variables. Only one of the
three is:

| Unknown | Does a build VM settle it? |
|---|---|
| Booter quirks untested on the current OpenCore | **No.** That is a `config.plist` question answered by booting a guest, not by where `OpenCore.efi` was compiled |
| Install-time RAM/SMP against P6's 7 GB budget | **No.** The install stays on the host (§3), so nothing about it changes |
| A compiler above the ceiling producing a green build with different bytes | **Yes, completely** — for the VM backend. The compiler is in the image, so "the host bumped GCC and nobody noticed" stops being a thing that can happen without someone editing a pin |

One of three is still worth having, because it is the one that fails
*silently*. `OvmfPkg` compiles clean under C23 and emits a **different**
`OVMF_CODE.fd` — `3373692a…` against `195c4dcf…`, same tree, same compiler,
one flag (measured, `decisions/0004`). That is the failure mode with no
error message.

**And a stale row the VM would make moot** (measured, found while preparing
this spec): `lib/compiler.sh` and `decisions/0004` both say gcc 14 is
"EXPECTED, not verified — nobody has built with 14." `ap-juicer` built
`opencore` (454 s) **and** `ovmf` (333 s) on **gcc 14.2.0** on 2026-09-21 and
went on to complete an install. The row has not been updated. That is worth
fixing whatever happens to this spec, and it is an illustration of the
problem: the range is a document that has to be maintained by hand, and the
image would be a fact.

### 2.3 `MQG_BUILD_DIR` is an input, and a VM makes it a constant

Measured, 2026-09-21, and it was found by accident: two cold builds of
identical sources, by the same compiler, on the same day, at
`…/ccache-verify/a` and `…/ccache-verify/w`, agreed on **one of eight**
artifacts — `OVMF_VARS.fd`, which holds no code. EDK II writes each module's
debug-symbol path into the PE image it emits. There is also a hard ceiling:
`image/build-image.sh:1357` refuses an `MQG_BUILD_DIR` longer than 120
characters, because EDK II enforces 255 bytes on debug symbol paths and its
own module paths use the rest — a limit discovered when a fresh-clone build
died **ten minutes in**, after compiling most of EDK II.

Inside a VM the build directory is whatever we say it is, identically on
every host. `/build` is six characters. **That is the single largest
reproducibility win available here**, and it is available today at zero risk
— see §7's paired experiment, which depends on it.

### 2.4 P5 measures things

`decisions/0007`: "P5 measures Product A's `run`". Measurements from an
uncontrolled build environment are worth less. **Reasoned**, and the
honest qualifier is that P5 measures the *guest*, and the guest is installed
by a stage that stays on the host either way (§3). The benefit to P5 is that
the boot stack under test is identical across the fleet, not that P5's
numbers get better.

## 3. Where the line falls

**The rule: everything that produces bytes moves in; everything that executes
Apple's bytes stays out.**

| Stage | Proposed | Why |
|---|---|---|
| `esd` | **in** | A fetch and a checksum. Its only consumer is `media`, which is in. Apple's 5.3 GB then never touches a host filesystem at all, which *strengthens* the never-publish rule rather than testing it |
| `opencore` | **in** | The whole point |
| `ovmf` | **in** | Same tree, same toolchain; they cannot be separated (`decisions/0004`: "Two artifacts, one tree") |
| `efi` | **in** | `sgdisk` + `mtools`, no privilege, no host knowledge |
| `openssh` | **in** | A fetch and an `unzip` |
| `payload` | **in** | `python3` and our own `mkflatpkg.py` |
| `media` | **in, entirely** | Both halves. `dmg2img` and the HFS+ assembly become one root context, and the nested microVM disappears (§3.2) |
| `target` | **host** | It creates the disk the install writes and the NVRAM the install boots. It belongs to the run, not to the build |
| `install` | **host** | §3.1 |
| `verify` | **host** | It talks over SSH to a guest running on the host |
| `manifest` | **host** | It records what this host ran, and it reads artifacts that must be on the host anyway |

### 3.1 Why the install cannot move, and why we should not want it to

Three reasons, in increasing order of importance.

1. **Nesting is not universally available.** `kvm_intel.nested = Y` here with
   no configuration (**measured**, ledger G17) — but it is a module
   parameter, other hosts may have it off, and **HVF and NVMM have no nested
   mode at all** (**inherited**, from the hypervisors' own documentation;
   nobody here has tried). A build VM that required nesting would be
   unavailable on exactly the macOS and NetBSD hosts `docs/test-hosts.md`
   exists to reach.
2. **Nobody has ever booted 10.9 under nested KVM** (**untested**). Doing so
   would place every existing guest finding — G3's CPU ladder, G13's
   EHCI+UHCI, G14's `IA32_MC0_CTL2` panic, G16's SATA presentation, G24's NIC
   ranking — on top of a hypervisor stack no other consumer of this project
   will ever run. The ledger would stop describing the thing we ship.
3. **P5 and `decisions/0007` require it to stay out.** P5 measures
   interactive GUI performance of Product A's `run` on the host. An install
   performed one layer deeper is not the install anyone will do.

So the build VM is **deliberately specified to require no nesting**. That is
a feature to write down, not an omission: it is what keeps the VM available
on every host that has an accelerator at all.

### 3.2 The consequence nobody asked about: privops collapses inward

Inside the build VM we are genuinely root. The entire reason
`lib/privops-qemu-linux.sh` exists — 572 lines of busybox initramfs, kernel
discovery across six candidate paths, module staging, `.ko.zst`
decompression, `modprobe --show-depends` ordering — is that an unprivileged
user on a Linux host cannot produce root-owned files on an HFS+ image.
Inside the VM that problem does not exist.

`lib/privops.sh` already names the backend that would replace it:

> `linux-sudo` — `mount -o loop` as root, honouring on-disk ownership.
> Simplest, but a standing privilege requirement on every build host.

The objection is the privilege requirement. In a disposable VM whose only
job is this build, the privilege is confined and the objection evaporates.
So: a new backend `linux-root`, selected by `MQG_PRIVOPS_BACKEND` exactly as
today, used only inside the VM.

**`qemu-linux` is not deleted.** It stays as the backend for the native
path (§3.3), it is the only one with a completed media build behind it on
three hosts, and the seam it established is the model this whole spec
copies.

**And a measured warning about what is lost.** Moving the media build into
the microVM on 2026-09-21 cost **+38 s, 1.5x** (78/79 s before, 112/117 s
after; six runs, primary host, same ESD, warm cache). The cause was named:
**busybox `sha256sum` at 193 MB/s against coreutils' 536 MB/s.** The cost
was not virtualization. It was the tooling chosen inside the VM. Hold on to
that number — it is §5's best evidence.

### 3.3 The seam: this is a backend, not a replacement

`MQG_BUILD_BACKEND`, defaulting to `native`, in the exact shape of
`MQG_PRIVOPS_BACKEND` and `MQG_PKG_MANAGER` and for the same stated reason:
a thing selected by the environment can be tested without the environment.

| Backend | For |
|---|---|
| `native` | What happens today. The only path on a host with no accelerator, and — as this spec is currently written — the only path on arm64 (§8.3, §3.3.1) |
| `qemu-linux` | The build VM, an **x86_64** guest under the host's accelerator |

Keeping `native` is not hedging. It is forced by §8's arm64 finding and by
the no-accelerator case, and it is what lets the two be compared at all —
§7's whole experiment is `native` against `qemu-linux` with one variable
changed.

### 3.3.1 The unification this spec does not yet get to have

`qemu-linux` as written above is an **x86_64 guest**, which is why arm64
hosts fall out of it: an x86_64 VM on an arm64 host is emulated, and §8.3
prices that at "a four-minute boot stack into hours". There is a shape that
would remove the exception entirely, and it deserves stating with its
evidence rather than being dismissed in a clause, which is what §8.3 did
until 2026-09-22.

| Host | Build VM | Toolchain EDK II invokes |
|---|---|---|
| x86_64 | x86_64 | `x86_64-linux-gnu-gcc` |
| arm64 | **arm64** | **the same `x86_64-linux-gnu-gcc`** |

Every VM runs its own host's ISA, so every VM runs under that host's own
hardware accelerator and nothing is ever emulated. Both invoke a compiler
that *targets* `x86_64-linux-gnu`, at the same pinned version, at the same
fixed path, producing X64 PE firmware either way. EDK II cross-compiles by
construction — the firmware is `-nostdlib`, freestanding, and targets a PE
format no Linux host runs natively, so "cross" is what this build already
is; the only thing that would change is the *host* of the cross-compiler.

If it holds, three things follow, and they are the reason it is worth the
scrutiny rather than a clause:

- **One row in `lib/compiler.sh`'s range table covers every host**, instead
  of one row per host architecture.
- **`decisions/0004`'s "reproducible per toolchain and not across them"
  could become a claim about hosts, not about toolchains** — a fixed
  cross-toolchain at a fixed path is the missing half of the pair whose
  other half (`MQG_BUILD_DIR`, §2.3) this spec already fixes.
- **P6 is served**, and §8.3 item 3 moves off the "does not fix" list.

**Status: untested, and split into three claims that must not be run
together.** §3.3.2 separates them; §8.3 carries the finding; §9.4 carries
the ledger entries. Nothing below is measured except where it says so.

### 3.3.2 Three claims, not one

The tempting mistake is to treat "a cross-compiler is host-independent" as a
single proposition. It is three, with three different severities and three
different ways of being tested.

| # | Claim | Status |
|---|---|---|
| **(A)** | A gcc that targets `x86_64-linux-gnu` emits the same X64 code whether the compiler binary itself is x86_64 or aarch64, given the same version, flags and sources | **Untested here.** Plausible — it is the premise reproducible cross-builds rest on — but this project has been wrong before about things that were merely plausible, and "plausible" is not one of §0's four labels |
| **(B)** | Debian's `gcc-13-x86-64-linux-gnu` package, built **for** an arm64 host, produces the same bytes as the same package built for an amd64 host | **Untested, and it needs arm64 hardware.** See below for why it cannot be approximated here |
| **(C)** | EDK II **BaseTools** — `GenFw`, `GenFv`, `GenSec`, `VfrCompile`, `BrotliCompress`, `DevicePath` — emit the same PE images when the BaseTools binaries themselves are aarch64 rather than x86_64 | **Untested, and it is the one nobody named.** §8.3's old clause conflated it out of existence |

(C) is the claim most likely to be false and the one with the worst failure
mode. BaseTools does not compile the firmware; it **post-processes** it.
`GenFw` performs the ELF→PE conversion and writes the debug-symbol path that
§2.3 already proves is an input. Those are host programs, compiled for the
VM's own architecture, and a green build with different bytes is exactly
what they would produce if any of their output depended on the host — struct
padding written to a file, an unstable sort, an iteration order. Both
architectures are little-endian LP64, which is the reason to expect (C) to
hold and is **not** a reason to assert it.

**The falsifier for all three, written now:** build the boot stack twice at
the same `MQG_BUILD_DIR` on the same UTC day, once in an x86_64 build VM and
once in an arm64 build VM, both at the same pinned `gcc-13-x86-64-linux-gnu`
version. **Eight identical checksums confirms (A), (B) and (C) together. Any
difference refutes the unification in its strong form**, and the next
question is which of the three did it — which `GenFw`'s output answers
faster than the firmware does, because a differing `.efi` with an identical
`.dll` intermediate is (C) and not (A).

**Why this could not be settled on an x86_64 host, measured 2026-09-22.**
The obvious cheap approximation — build once with `gcc`, once with
`x86_64-linux-gnu-gcc`, compare — is **vacuous on a Debian-family x86_64
host, and vacuous for a structural reason worth writing down**: Debian's
multiarch toolchain scheme makes the native compiler *be* the cross
compiler for its own triplet. On the primary host (Ubuntu 24.04, amd64):

| Path | Resolves to | Owning package |
|---|---|---|
| `/usr/bin/gcc` → `gcc-13` → | `/usr/bin/x86_64-linux-gnu-gcc-13` | `gcc-13-x86-64-linux-gnu 13.3.0-6ubuntu2~24.04.1` |
| `/usr/bin/x86_64-linux-gnu-gcc` → | `/usr/bin/x86_64-linux-gnu-gcc-13` | *the same file — same device:inode, `32:3353112`* |

`gcc` and `gcc-x86-64-linux-gnu` are both version `4:13.2.0-7ubuntu1`, both
from `gcc-defaults`, and neither ships a compiler binary: they ship
symlinks. The same is true of every binutil the build uses — `/usr/bin/objcopy`,
`ar`, `ld`, `nm`, `strip` all resolve to their `x86_64-linux-gnu-`-prefixed
selves. So **there is exactly one compiler binary on this host, and the two
names are two names for it.** Confirmed three ways, 2026-09-22 (**measured**,
`NOTES.md`): identical device:inode; `-print-search-dirs` and
`-print-prog-name=cc1` identical; and a freestanding `-std=gnu17 -O2 -c`
compile of the same source through both names producing a byte-identical
object, `dbde06fc…`. The only difference in `gcc -v` between the two is the
`COLLECT_GCC=` line, which is an echo of `argv[0]`.

Running the eight-artifact comparison through those two names would have
produced eight matches and told us nothing, so **it was not run**, on the
same grounds `NOTES.md` records for ccache: a comparison that cannot fail is
not evidence. What (B) actually names is `gcc-13-x86-64-linux-gnu` built
**for arm64** — a package that by definition does not exist on an amd64 host.

## 4. The image: which artifact, which tier, how it is pinned

### 4.1 The tier is 1, and the reasoning matters more than the number

`decisions/0004`: Tier 0 is built from pinned source by our own scripts;
Tier 1 is vanilla upstream, version-pinned and checksummed; Tier 2 is
quarantined and never shipped.

A distribution's published rootfs tarball or netboot kernel, pinned by
digest, is **Tier 1** — the same standing as Lilu's release zip and
VirtualSMC's. We do not build it; we take upstream's bytes and checksum
them. Calling it Tier 0 because "we assemble the VM" would be precisely the
lie `decisions/0004` exists to prevent.

But it is a **different kind of Tier 1 from Lilu**, and `INGREDIENTS.md`
already has the vocabulary for the difference. Lilu's bytes ship, inside the
EFI image. **No byte of the build VM's rootfs ever reaches an image.** What
reaches an image is *its compiler's output* — which is exactly the
distinction `INGREDIENTS.md` draws today between `gcc` (a row, because its
output ships) and `bats` (not an ingredient, because none of its bytes reach
an image). The build VM sits with `gcc`, not with `bats`, and not with Lilu.

### 4.2 How it enters `INGREDIENTS.md`

- **Pin registry.** `vendor/sources.tsv` gains `buildvm-rootfs` (and
  `buildvm-kernel`, if the distribution ships them separately), name + URL +
  sha256, like every other row. `bin/verify-changed-sources.sh` already
  fails a commit that moves a URL without moving its checksum.
- **Fingerprint.** `bin/ingredient-fingerprint.sh` must count it, so it lands
  in every manifest as `ingredient.buildvm-rootfs` and in the `ingredients`
  digest.
- **Stage stamps — this one is load-bearing.** The `<output>.inputs` record
  for `opencore`, `ovmf`, `efi`, `payload` and `media` **must include the
  build-VM image digest.** Otherwise a changed image leaves the built `.efi`
  sitting there, the stage skips, and we ship firmware from a toolchain the
  manifest does not describe — the exact failure `INGREDIENTS.md` item (4)
  was written to stop.
  Note this is the **inverse** of the ccache decision. ccache is *claimed*
  not to change bytes, so its stamps deliberately exclude it ("installing
  ccache must not rebuild the firmware"). The VM image is *known* to change
  bytes, so it must be included. Both follow the same rule: the stamp
  contains what changes the output.
- **Manifest.** Two new lines, in the shape of `compiler`/`compilerrange`:
  `buildbackend` (which backend built this image) and `buildvm` (which image
  digest, or `none`). `compilerrange` cannot be dropped — a native build
  still needs it, and an image built by an out-of-range compiler must carry
  "this was untested territory" forever, because the range moves and the
  image does not.

### 4.3 What Renovate does when it moves

**Nothing automatic, and the row should say so honestly.**

- A rootfs tarball at a versioned URL has **no clean Renovate datasource**.
  A `regex` custom manager scraping a release index is exactly the "fragile
  tracker invented to fill a cell" `INGREDIENTS.md` warns against, and it
  would rewrite a URL beside a checksum it cannot compute.
- **The tempting alternative, and why not.** Renovate's `docker` datasource
  *does* track `alpine` and `debian` by digest. But consuming an OCI image
  means unpacking OCI layers, which means `skopeo` or `umoci` on the host —
  a new host dependency, in a change whose entire purpose is to remove host
  dependencies. Rejected on those grounds, not on principle.
- **What compensates:** the checksum, `bin/verify-changed-sources.sh`, and
  the fact that a bump here is a **decision, not a merge**. Moving the image
  moves the compiler, which moves the bytes, which invalidates every golden
  on disk *and* every checksum in `decisions/0004`'s table. Automerge off,
  for the same three reasons the boot stack has it off, plus a fourth: the
  bump is only complete when the eight artifact checksums have been re-taken
  and the table re-written.

### 4.4 The trap: pinning the rootfs does not pin the compiler

This is the part most likely to be got wrong, and it would produce something
that *looks* pinned and is not.

A minirootfs tarball pinned by digest contains a package manager and almost
nothing else. The moment provisioning runs `apk add gcc` or
`apt-get install gcc`, the compiler comes from whatever the mirror is serving
**today**. The rootfs digest pins the starting point; it does not pin the
toolchain, which is the whole objective.

Three ways out:

| Option | What it gives | What it costs |
|---|---|---|
| **(i) Exact version pins against a durable archive** — every package named `name=version` and fetched from an immutable snapshot | A genuinely pinned toolchain, reproducible by anyone with the URL | Needs a distribution that *has* a durable archive. `snapshot.debian.org` is immutable and archived indefinitely (**inherited**, from Debian's own documentation); `snapshot.ubuntu.com` exists since 2023 (**inherited**, unverified here). Alpine's mirrors drop superseded packages within a release branch (**inherited**, and it is the failure mode to check) |
| **(ii) Provision once, checksum the result** | Honest about what it is | The provisioned disk is a local blob no other host can reproduce. Every host would have a different one, which defeats "the same environment everywhere". This is a **Tier 2** artifact wearing a Tier 1 hat |
| **(iii) Build the toolchain from source in the VM** | Tier 0 all the way down | Weeks. Out of scope, and out of proportion |

**Recommendation: (i), and the choice of distribution follows from whether
(i) is available there** — which is §5's real question, not musl.

**The falsifier, named before anyone runs anything:** take the exact package
URL that (i) would pin today, write it down with its date, and fetch it again
in 90 days. **If it 404s, (i) is refuted for that distribution** and the
choice collapses to (ii) or to a distribution that keeps its archive. This
costs one `curl` today and one in 90 days, and it settles the question that
otherwise gets discovered when a build stops reproducing a year from now.

## 5. Alpine, or not

The brief asks for this to be answered rather than assumed, so here is the
answer with its evidence: **probably not Alpine, and the reason is not musl.**

### 5.1 The case for Alpine, examined

- **Small.** A minirootfs is a few megabytes, a netboot kernel a few tens
  (**inherited**, from Alpine's published sizes; nobody here has fetched one,
  and this spec does not).
- **Static busybox by default**, which is "the trap that cost a run on
  ap-juicer". **This is the one to correct** (§2.1, measured): that trap cost
  *no* run, on any host. It was reasoned about and guarded against before it
  bit. And it is moot either way — the dynamic-busybox hazard belongs to the
  privops initramfs, which §3.2 retires inside the VM in favour of
  `linux-root`. Alpine would be solving a problem that will not exist.

### 5.2 The case against, in order of how much evidence there is

**(a) busybox coreutils — measured, and it is the strongest objection.**

Measured on the primary host, busybox 1.36.1, 2026-09-21:

| GNU-ism | busybox |
|---|---|
| `stat -c FMT` | **yes** |
| `truncate -s` | **yes** |
| `find -printf` | **no** |
| `cp --reflink` | **no** |

So a busybox userland breaks two of the four classes outright. The four
affected call sites — `find -printf` at `lib/efi.sh:103,107` and
`cp --reflink` at `lib/golden.sh:52` and `bin/triangulate.sh:439` — would
have to be rewritten, or `coreutils` and `findutils` added back, at which
point the smallness argument is gone. (Both `cp --reflink` sites are
host-side and would not move into the VM at all, which weakens the objection
slightly and does not remove it: a busybox image still cannot run
`lib/efi.sh`, and `lib/efi.sh` is the `efi` stage.)

Worse, and this is the number that decides it: **moving the media build into
a busybox environment cost +38 s, 1.5x, and the measured cause was busybox
`sha256sum` running at 193 MB/s against coreutils' 536 MB/s**
(`NOTES.md:5456`). We have already run this experiment, on this project's own
workload, and busybox lost by 2.8x on the one operation the build does most.
A build VM that does the *whole* pipeline with busybox tooling would pay that
tax on `esd`, `media`, `manifest` and every checksum in between.

**(b) musl and EDK II BaseTools — untested, and a real risk.**

BaseTools is C that has only ever been compiled against glibc here. Two
things are worth separating, because they have very different severities:

- **The host programs** — `GenFw`, `GenFv`, `GenSec`, `VfrCompile`,
  `BrotliCompress`, and `DevicePath` — link against libc and against
  `libuuid`. These are where a musl failure would appear. **Severity: a
  build failure with a compiler error**, which is the good kind: loud,
  immediate, and at a known place. `ap-juicer`'s `uuid/uuid.h` failure
  (§2.1) is the same class and took 92 s to surface.
- **The firmware itself** is freestanding, `-nostdlib`, targeting X64 PE. No
  libc links into it. So musl should not change the shipped bytes
  (**reasoned, not measured**) — but Alpine's gcc is a *different gcc build*
  with different configure defaults, and whether any of those reach the
  emitted PE is **untested**. Severity: a green build with different bytes,
  which is the bad kind, and it is exactly the failure mode
  `decisions/0004` records for `-std=c2x`.

**How the musl risk surfaces early rather than at stage two.** Make it
**step zero**, before any pipeline wiring exists and before a distribution is
chosen:

> In each candidate image, unpack the pinned `audk` tarball and run
> `make -C BaseTools` and nothing else.

That is minutes, not the 92 s + 454 s the pipeline would take to reach the
same point, and it is a clean binary outcome. **Falsifier, written now:** if
BaseTools does not build under musl and the fix is larger than adding a
package and `-D_GNU_SOURCE`, **Alpine is out** — because patching upstream
BaseTools to suit a libc upstream never used is the fork `decisions/0004`
already refused to start ("a fork we did not intend to have, growing by a
hunk per compiler release").

Run step zero on **both** candidates, so the comparison is a measurement and
not an argument.

**(c) No durable package archive — §4.4's falsifier.** If Alpine's mirrors
do not serve the pinned versions in 90 days, option (i) is unavailable there,
and Alpine cannot deliver the pinned toolchain that is the main prize.

### 5.3 What to choose instead, and the argument that decides it

**A glibc, GNU-coreutils distribution with an immutable package archive, at a
gcc version inside `lib/compiler.sh`'s declared range.**

The decisive argument is not comfort. It is that this project's one verified
compiler is **gcc 13.3.0 (Ubuntu `13.3.0-6ubuntu2~24.04.1`)**, and every
checksum in `decisions/0004`'s table was produced by it. An image carrying
*that* compiler makes §7's experiment a checksum comparison against a table
we already have, instead of a new baseline with nothing to compare to. That
is the difference between an experiment that can fail informatively and one
that can only produce a number.

`ap-juicer`'s successful gcc 14.2.0 build (§2.2) means 14 is also defensible
and is in fact better supported by evidence than the documents currently
admit. Anything at 15 or above is outside the range and would need the
ceiling moved on evidence first.

**Alpine is not ruled out by argument. It is ruled out by two measurements
and reinstated by one:** run step zero on both, and if the glibc candidate's
archive turns out not to be durable while Alpine's is, the calculus changes.

**§3.3.1 does not change this section's conclusion, and it is worth saying
why, because it looks as though it should.** The decisive argument above is
that the image should carry *our verified compiler*, and §3.3.1 proposes
carrying a cross-toolchain instead — which sounds like a different compiler
and therefore a new baseline with nothing to compare against. On a
Debian-family image it is not a different compiler. **Measured on the
primary host, 2026-09-22:** this project's one verified compiler, gcc 13.3.0
(`13.3.0-6ubuntu2~24.04.1`), is shipped by the package
**`gcc-13-x86-64-linux-gnu`** — the triplet-named one — and `gcc-13` and
`gcc-x86-64-linux-gnu` are symlink packages over that single binary
(§3.3.2). So "pin our verified compiler" and "pin an `x86_64-linux-gnu`
cross-gcc" **name the same package at the same version**, and §7.2's
experiment stays a comparison against `decisions/0004`'s existing table
rather than becoming a new baseline.

That is an argument *for* the glibc, Debian-family choice that §5.3 already
reaches, and it is one this section did not have: the distribution whose
archive is durable is also the one whose packaging makes the cross-toolchain
and the verified toolchain the same artifact. **What it is not** is evidence
for §3.3.2 (B). Being the same package on amd64 says nothing about whether
that package, built for arm64, emits the same bytes. Keeping those apart is
the whole of §3.3.2.

## 6. How the host talks to it, and what persists

### 6.1 Sizes, measured 2026-09-21 on the primary host

| Thing | Size | Files |
|---|---|---|
| `$MQG_BUILD_DIR` | **1.4 GiB** (of which `OpenCorePkg-1.0.7/` is 1.3 GiB) | **40,243** |
| Installer media image | **7,089,422,336 bytes** (6.6 GiB); 6.41 GB of content in ~52,290 entries | |
| `InstallESD.dmg` | **5,318,660,434 bytes** | |
| Boot-stack artifacts out | `build/firmware/` **8.1 MiB**, `artifacts/` 844 KiB | |
| EFI image out | 192 MiB | |
| Payload out | 1,658,422 bytes | |

**40,243 files** is the number that decides the data path.

### 6.2 The build tree persists inside the VM, on its own disk

**Decision: `$MQG_BUILD_DIR` lives on a persistent qcow2 attached to the VM,
at a fixed path inside it. It is never a host directory shared in.**

Three reasons:

1. **40,243 files.** This project has already measured what per-file latency
   does to it: 18 ms per file create over NFSv3 against 0.06 ms local, a
   **156x** difference that forced `decisions/0003` and moved both the images
   and the Tier 2 quarantine off the repository. 9p and virtiofs both pay
   per-file costs; a virtio block device pays none. (The host's QEMU 8.2.2
   offers `virtio-9p-pci` and ships a `virtiofsd`, **measured** — but
   virtiofsd unprivileged is **untested** here, and a daemon that may need
   privilege is the wrong dependency for a change made to remove
   dependencies.)
2. **The path must be a constant across hosts** (§2.3). A shared host
   directory carries the host's path into the PE images. A disk inside the
   VM can be mounted at `/build` everywhere.
3. **It is the data path that already works.** `privops_run` attaches images
   as virtio disks and copies nothing. This is that, one size up.

Consequences that fall out of it:

- **ccache**, which lives at `$MQG_BUILD_DIR/ccache` and is kept out of the
  repository because "the repo is NFS at 9–15 ms per file create and a ccache
  directory is thousands of small files", is on local storage by
  construction, on every host.
- **ccache finally becomes measurable.** `INGREDIENTS.md` records that
  ccache is off by default because it is not installed on the primary host,
  so "a cache hit against a cold compile" has never been compared. In the
  image it is one line in a package list, and the comparison that
  `lib/ccache.sh` names three files to update can actually be run. This is a
  side benefit, not a justification.
- **The 120-character `MQG_BUILD_DIR` limit stops mattering.** `/build` is 6.

### 6.3 What crosses the boundary, and how

| Direction | What | Mechanism |
|---|---|---|
| **in** | The repository's scripts | A small read-only filesystem image built from the working tree each invocation, attached as a block device. Not 9p: it is a few MB, it is read-only, and building it from `git archive` (or from the tree, with the dirty flag the manifest already records) makes "which commit built this" exact |
| **in** | Vendor tarballs, Apple's ESD | Not crossed at all — fetched **inside**, onto the persistent disk |
| **out** | The media image, 6.6 GiB | **Unchanged from today.** The host pre-creates the sparse file, attaches it as a block device, the VM writes HFS+ into it. This is exactly what `privops_run`'s first argument does now |
| **out** | Eight boot-stack artifacts, the EFI image, the payload, `SHA256SUMS`, logs — ~200 MiB | One "outbox" raw device. The VM writes an uncompressed `tar` stream to it; the host runs `tar -xf` on the raw file, whose trailing zeros `tar` stops at. Needs only `tar`, which is already required, and no filesystem driver on the host |
| **out** | Console, markers, progress | `MQG_PRIVOPS_CONSOLE` already does this |

**Networking:** QEMU user networking (slirp), which needs no privilege and is
already how the macOS guest reaches the network. A side benefit worth
naming: `unshare -rn` was used to demonstrate that the boot stack builds
offline (**measured**, `decisions/0004`). In a VM the same demonstration is
`-nic none`, which is stronger and needs no unprivileged user namespaces.

### 6.4 `--freshness` and the stage stamps

The `<output>.inputs` stamps live beside their outputs — which now means
inside the VM. So `--freshness`, which today answers "would my next build
rebuild the firmware, and why" **in a second instead of in fourteen
minutes**, has to ask the VM.

Two shapes:

- **(a) Run the pipeline's build half inside the VM**, so freshness is
  computed where the stamps are. `--freshness` on the host becomes "boot the
  VM and ask it". One copy of the truth. Costs a VM boot.
- **(b) Mirror the stamps out** after every stage, so the host can answer
  locally. Fast, and two copies of the truth that can disagree — which is the
  bug class `INGREDIENTS.md` item (4) exists to prevent.

**Recommendation: (a), with a named ceiling.** A `microvm` machine type with
a small kernel boots in well under a second (**inherited**; QEMU 8.2.2 offers
`microvm`, **measured**). **If a `--freshness` answer costs more than 10 s,
(a) is refuted and (b) has to be built** — and if (b) cannot be made
trustworthy, that is an argument against the whole change, because the
resumable pipeline is what makes an hour-long build debuggable.

## 7. What it costs, and what would abandon it

### 7.1 The baselines that exist

| Host | `opencore` | `ovmf` | Conditions |
|---|---|---|---|
| **pet-power-plant** (6C/12T, 2018, gcc 13.3.0) | 174–230 s cold | 82–170 s cold | `NOTES.md:3001`, `:1062`, `:5306` |
| pet-power-plant | **20 s** warm | **11 s** warm | `NOTES.md:435`, `:1063` |
| squirrel-zapper (2 cores, 2015, gcc 16.2.1) | 391–439 s | 227–241 s | salvaged reports |
| ap-juicer (Xeon 5150, 3 of 4 cores online, 2006, gcc 14.2.0) | **454 s** | **333 s** | `…-20260921-164808/report.txt` |

**A correction to the brief** (measured): "395–454 s and 228–333 s on real
hardware" are the *slow* hosts — a two-core 2015 laptop and a 2006 Xeon. The
primary host does the whole boot stack cold in **230 s and 236 s** for both
packages together. That is the number a VM has to be compared against, and
it is four minutes, not thirteen.

### 7.2 The measurement that settles it

**This project has already run exactly the right experiment, with a known
null result, and the VM experiment should be a copy of it.**

On 2026-09-21 the ccache seam was validated by two cold boot-stack builds on
the primary host, **at the same build directory**, **on the same UTC day**,
one straight and one through the PATH shim: **230 s and 236 s, and all eight
artifacts identical** (`NOTES.md:5288`). One variable, a paired comparison,
and a result that could have failed.

So:

> **Two cold boot-stack builds on the primary host, on the same UTC day, with
> `MQG_BUILD_DIR` set to the identical path string on both sides and the same
> gcc version on both sides. One `native`. One `qemu-linux`, with vCPUs equal
> to the host's core count. Compare (1) wall time per stage and (2) all eight
> artifact checksums against `decisions/0004`'s table.**

Both controls are load-bearing and both were learned the hard way: the path
string, because two builds at different paths agreed on 1 of 8 artifacts; the
same UTC day, because `OpenCore.efi` embeds the build date and differs in
exactly two bytes across days.

### 7.3 Predictions, written before anyone runs anything

- **Time: near-native.** A CPU-bound compile under a hardware accelerator on
  the same ISA runs on the same cores. **Reasoned, not measured** — and
  "should be near-native" is how this project has been wrong repeatedly, so
  it is a prediction, not a premise. The doubt is I/O: 40,243 files into a
  qcow2, with the guest's page cache in the way.
- **Checksums: all eight identical.** If the compiler version and the path
  string match, nothing left should differ. **If they differ, the VM has
  introduced an input nobody has identified — and finding that input is more
  valuable than the timing result**, because it would be a third entry
  alongside the build date and the build directory.

### 7.4 What abandons it

Named now, so that nobody gets to decide afterwards what the number meant.

| Result | Conclusion |
|---|---|
| Cold boot stack in the VM > **1.5x** native on the same host | Too expensive for the interactive loop. Keep the VM as an optional backend for foreign hosts only; do not make it the default |
| Warm rebuild > **60 s** (against 31 s native for both stages) | Incremental development is damaged. Same conclusion |
| `--freshness` > **10 s** | §6.4(a) is refuted; build (b) or abandon |
| **Eight checksums differ**, with compiler and path held equal, **and the cause is not found** | **Stop.** An environment that claims to be controlled and is not is worse than the honest uncontrolled one we have, because it would license a reproducibility claim that is false |
| BaseTools will not build in either candidate image (§5.2 step zero) | Stop before anything else is written |
| Pinned packages 404 at 90 days in every candidate (§4.4) | The toolchain cannot be pinned, so the main prize is unavailable. Reconsider from scratch |

## 8. What it does not fix

Honest list. Several of these are load-bearing.

1. **The install still runs on the host**, still needs a working accelerator,
   still needs a `-cpu` line from `lib/cpu.sh`'s ladder that the host can
   actually provide, and still needs the RAM. Nothing in §3 changes any of
   it.
2. **`MacPro5,1` still does not work under KVM.** G14 is a guest-plus-KVM
   fact — `IA32_MC0_CTL2` at `RCX: 0x280`, a #GP that `ignore_msrs` cannot
   suppress. A build VM is not adjacent to it.
3. **It does not serve P6 as specified — but the reason it was said not to
   was wrong, and the correction is §3.3.1.** P6 targets GitHub's **arm64**
   macOS runners. An x86_64 Linux build VM there would be emulated, turning
   a four-minute boot stack into hours (**reasoned**; the ratio is untested).
   That part stands.

   What does **not** stand is the sentence this item used to carry: that an
   arm64 build VM "would need an x86_64-targeting cross-gcc — a third
   compiler, different bytes, a new row in the range table." **"Different
   bytes" was an assumption stated as a finding**, and it is the fifth
   instance of the failure §0 exists to catch — an inherited claim nobody
   checked, this time inherited from ourselves. A cross-compiler's output is
   not obviously a function of the machine it runs on; that it is not is the
   premise every reproducible cross-build rests on, and EDK II cross-compiles
   by construction (the firmware is freestanding X64 PE, which no Linux host
   runs natively).

   Nor would it be "a third compiler". On a Debian-family host the
   x86_64-targeting compiler **is** the native one: `/usr/bin/gcc` and
   `/usr/bin/x86_64-linux-gnu-gcc` are the same file, same device:inode, both
   from `gcc-13-x86-64-linux-gnu` (**measured**, primary host, 2026-09-22 —
   §3.3.1, `NOTES.md`). Adopting the triplet-prefixed name changes nothing
   about *which* compiler this project carries; it changes only which host
   that package was built for.

   So the honest statement of the item is narrower and more useful:

   > **An arm64 build VM running an `x86_64-linux-gnu` cross-gcc would serve
   > P6 and would unify the backend table (§3.3.1), if and only if claims
   > (A), (B) and (C) of §3.3.2 hold. All three are UNTESTED, and none can be
   > tested on an x86_64 host** — the cheap approximation is vacuous for a
   > structural reason (§3.3.2), so the evidence needs arm64 hardware and
   > nothing less.

   The claim most likely to break it is **(C)**, EDK II's BaseTools, which
   the old clause did not mention at all: BaseTools are host programs that
   post-process the firmware, and their failure mode is a green build with
   different bytes. **Either way P6 must still decide separately**, and this
   spec does not decide for it — but it no longer tells P6 that the door is
   closed, because it never established that.
4. **It does not fix the 41 GNU-only call sites. It freezes them.** The
   portability problem becomes a pinning problem for the stages that move in
   — which is a real gain — but `vm/run.sh`, `vm/clone.sh`, `vm/golden.sh`,
   `lib/golden.sh`, `bin/triangulate.sh` and everything in `image/` after
   `media` still run on the host and still need portable shell.
   `bin/bash32-check.sh` still binds everywhere.
5. **It does not deliver byte-identity for free.** It makes it *possible* for
   the first time, by pinning the compiler and fixing the path. It does not
   touch `OpenCore.efi`'s embedded build date, which still differs in two
   bytes across UTC days. `SOURCE_DATE_EPOCH`-style determinism remains a
   separate piece of work.
6. **It adds a QEMU dependency to the build, where before QEMU was only a
   runtime dependency.** G6 (QEMU version unpinned, 8.2.2 here, 11.1.1 and
   11.0.2 elsewhere) grows a blast radius: the same unpinned QEMU now runs
   both the build and the guest.
7. **It does not help a host with no accelerator.** Under TCG the build VM is
   unusable, so `native` must remain (§3.3). Which means the host-tooling
   portability work is not retired, only made optional.
8. **It does not shrink the media (6.6 GiB) or the install (780–1656 s).**
   `media` 426 s and `install` 1656 s on `ap-juicer` are the same numbers
   afterwards.
9. **It does not measure ccache.** It makes measuring it cheap (§6.2). Those
   are different things, and `INGREDIENTS.md`'s ccache row stays exactly as
   it is until someone runs the comparison.
10. **It adds an ingredient with a weak tracker** (§4.3) and a new class of
    silent staleness: a stale VM image that still builds.
11. **G1 is untouched.** Apple's EULA is a legal constraint about the
    hardware, not the build environment.

## 9. What it means for `bin/triangulate.sh` and the ledger

This is the largest consequence and it should not be left for later.

### 9.1 `--probe`'s tool list splits in two

`RUNTIME_TOOLS` and `BUILD_TOOLS` (18 unique names across the two) and
`boot/prereqs.sh`'s `REQUIRED` (36 rows) currently answer one question: *does this host have what
the build needs?* After the change there are two questions, and one list
cannot answer both.

| Becomes a question about the **image** | Stays a question about the **host** |
|---|---|
| `gcc` `make` `git` `python3` `nasm` `iasl` `zip` `unzip` `curl` `openssl` `mcopy` `mformat` `mmd` `mdir` `sgdisk` `dmg2img` `mkfs.hfsplus` `xxd` `7z` `cpio` `busybox`, and the `uuid/uuid.h` header | `qemu-system-x86_64` `qemu-img` `ssh` `ssh-keygen` `tar` `sha256sum` `bats` (the suite runs on the host), plus the coreutils the host-side scripts use |

Concretely: `boot/prereqs.sh`'s table gains a column or becomes two tables;
`bin/triangulate.sh` gains a third list; and **`tests/boot_scripts.bats`,
which asserts the two lists agree, must learn that there are now two
agreements to check, not one.** That test exists because there were once
three lists that disagreed and a host stopped on `zip`. Splitting the lists
without splitting the test would recreate exactly that.

The host list shrinking from 36 to about 7 **is the portability win, stated
as a number.**

### 9.2 What happens to `--build`

`--build` today takes about ten minutes and its real deliverable is ledger
rows about *that host's toolchain*. After the change, the toolchain is the
same everywhere, so `--build` stops testing it. It becomes "can this host
run the build VM, and how fast" — worth running once per host, and much less
informative per run.

**That is a loss as well as a saving, and the spec should say so.** Three
findings that exist only because the build ran on the host: the `uuid/uuid.h`
header check (which produced `boot/prereqs.sh`'s entire `REQUIRED_HEADERS`
mechanism), G26's udisks-needs-a-seat finding (which produced the whole-media
microVM build and matters for **any** headless host, CI included), and G12's
NFS numbers measured from the server side. That class of finding stops
arriving. `--probe` keeps everything it was actually good at — the `-cpu`
ladder, QEMU device availability, accelerator, nested, NIC, RAM, topology —
and that is where the fleet's value always was.

### 9.3 Ledger dispositions

`docs/host-profile.md` §4, entry by entry. The rule this project already
follows: **struck rows are kept, not deleted, because the class of assumption
is the finding.** An entry whose subject silently moves from the host to the
VM would be the fifth instance of the inherited-claim failure this project
keeps catching. So no entry is edited in place; each that changes subject
gets its original struck and a new row added.

| Entry | After |
|---|---|
| G1 (Apple hardware / EULA) | Unchanged |
| G2 (Intel + VT-x) | Unchanged, **but its scope widens**: VT-x is now needed for the *build* too, not only the install |
| G3, G13, G14, G16, G19, G24, G25 | **Untouched.** These are guest and accelerator facts. This is the good news: what remains in the ledger afterwards is precisely the part that always had the content |
| G4 (core count) | Unchanged — host topology, and now also sets the VM's vCPU count |
| G6 (QEMU 8.2.2) | Unchanged claim, **larger consequence** (§8.6) |
| G8 (RAM and free space) | Unchanged, plus ~2–3 GB for the work disk. Worth noting against P6's 14 GB budget |
| G9, G12 (NFS) | **Partly resolved for the build**: `$MQG_BUILD_DIR` is inside a qcow2 on local storage by construction, on every host, rather than by each host getting `MQG_IMAGE_DIR` right |
| G10 (reflink), G11 (`chattr +C`) | Unchanged — golden promotion stays host-side. G11 now also applies to the work disk |
| G17 (nested virt) | Unchanged, and **explicitly not required** (§3.1). Worth writing into the entry: the build VM was specified so as not to need it |
| G20 (media corruption) | Unchanged and still portable. One writer, one lock, one post-unmount check against `media/apple-packages.sha256` |
| ~~G22~~ (host C compiler unpinned) | **The big one. It splits.** The claim stays true of `native` and becomes false of `qemu-linux`. Struck original, plus a new row, plus the two new manifest lines (§4.2) so an image says which backend made it. **It does not split a second time by host architecture** unless §3.3.2's claims fail: under §3.3.1 one pinned `x86_64-linux-gnu` toolchain is the pin on every host, and the new row says "pinned" without an architecture qualifier. **If (A), (B) or (C) fails, the new row needs that qualifier and the range table needs a row per host arch** — which is the cost §8.3 used to assert without evidence |
| ~~G23~~, ~~G26~~ | Already resolved. Both become moot *inside* the VM and stay live for `native` |

### 9.4 New entries the change creates

| New | Claim | What another host would need |
|---|---|---|
| **G27** | The host can run a Linux VM **of its own ISA** under a hardware accelerator, so the build VM is available at all | Any host without KVM/HVF/NVMM falls back to `native`. **Untested on HVF and NVMM.** The arm64 exception that was here has moved to G30: an arm64 host can run an arm64 VM under HVF perfectly well — what is unsettled is the *toolchain* inside it, not the VM |
| **G28** | The build VM's distribution and libc compile EDK II BaseTools | §5.2 step zero answers it in minutes. **Untested** |
| **G29** | The pinned package archive still serves the pinned versions | §4.4's 90-day `curl`. **Untested by construction — it is a claim about the future** |
| **G30** | An `x86_64-linux-gnu` cross-gcc emits the same X64 firmware bytes whether it runs on an x86_64 or an arm64 host — §3.3.2 (A) and (B) together | **An arm64 host, and nothing less.** The x86_64-only approximation is vacuous: `gcc` and `x86_64-linux-gnu-gcc` are one file on a Debian-family amd64 host (**measured**, 2026-09-22). If G30 holds, the backend table collapses to one row and §8.3 item 3 comes off the list. **Untested** |
| **G31** | EDK II BaseTools emit the same PE images when built for aarch64 rather than x86_64 — §3.3.2 (C) | The same arm64 host, in the same run as G30, but it is a **separate claim with a separate falsifier**: compare the intermediate `.dll` against the final `.efi`, which tells G31 apart from G30 without a second build. This is the claim §8.3's old clause omitted entirely, and the one whose failure is silent. **Untested** |

## 10. Exit criteria

This is a spec, so its exit is a decision, not an artifact.

**The change is worth making if, and only if:**

1. Step zero (§5.2) builds BaseTools in at least one candidate image.
2. §4.4's option (i) is available in that image's distribution — pinned
   package versions from an immutable archive.
3. §7.2's paired experiment produces **eight identical checksums** against
   `decisions/0004`'s table, with compiler and path held equal.
4. None of §7.4's thresholds trips.

**Exit:** a `docs/decisions/0011-*.md` recording which image, which tier,
which pins, and the eight checksums — or recording why the idea was dropped
and which measurement dropped it. Either outcome is a result. An outcome
that is neither is a spec that was never tested.

## 11. Stop and ask

In addition to the standing list in §3 of the umbrella design:

- **Before fetching any distribution image.** This spec deliberately fetched
  nothing.
- Before installing anything on any host, or using `sudo` for any part of it.
- If the VM image would need to be published, cached in a public place, or
  carried between hosts by anything other than its pin — anything holding
  Apple's ESD or a built media image is subject to the never-publish rule,
  and the work disk holds both.
- If step zero's failure turns out to need a patch to upstream BaseTools.
  That is the fork `decisions/0004` refused to start.

## 12. What this spec does not settle

- **Which distribution.** Step zero and the 90-day archive check decide it;
  §5 states the criteria and a leaning, not a conclusion.
- **Whether `native` is ever removed.** §8.7 and §8.3 say it cannot be, for
  now. Whether it becomes unsupported rather than merely non-default is a
  later decision with its own evidence.
- **P6.** §8.3 is a finding, not a plan. What an arm64 runner should do is
  P6's decision. §3.3.1's unification is the shape that would serve P6 and
  collapse the backend table to one row; §3.3.2's three claims are what it
  rests on, all **untested**, and **none of them testable without arm64
  hardware** — the x86_64-only approximation was attempted on 2026-09-22 and
  found vacuous, for a structural reason now recorded in `NOTES.md`. G30 and
  G31 (§9.4) are where a host with that hardware would report.
- **Whether the install could ever move in**, on a host with nesting. §3.1
  argues it should not, on grounds that are about measurement validity rather
  than feasibility. A future spec could revisit it; this one does not.
- **What happens to the ten `ap-juicer` and `squirrel-zapper` triangulation
  log directories in the repository root.** They are evidence for §2.1 and
  §7.1 and should outlive this change, but where they live is not this
  spec's question.
- **Whether `decisions/0004`'s checksum table should be re-taken under the
  VM.** If §7.2 produces eight matches, the table is confirmed rather than
  replaced. If it produces eight different-but-explicable checksums, whether
  the table moves is a decision with consequences for every golden on disk.

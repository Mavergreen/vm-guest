# Host profile and generalization ledger

Two jobs. It records what this host actually is, and it accumulates every
host-specific assumption we make — so that porting to another host is a matter
of working through a list rather than rediscovering what was baked in.

**When any phase relies on something specific to this machine, add it to §4.**

## 1. Primary host — probed 2026-09-17

| | |
|---|---|
| Model | `Macmini8,1` (Mac mini 2018), board `Mac-7BA5B2DFE22DDD8C` |
| Vendor | Apple Inc. — **the host is Apple hardware** |
| CPU | Intel Core i7-8700B @ 3.20 GHz, Coffee Lake, family 6 model 158 stepping 10 |
| Topology | 1 socket, 6 cores, 2 threads/core, 12 logical CPUs, 1 NUMA node |
| Clocks | 800 MHz min, 4600 MHz max |
| Virtualization | VT-x present; `vmx` in flags; `ept`, `vpid`, `ept_ad` |
| Notable ISA | `avx`, `avx2`, `aes`, `rdrand`, `rdseed`, `bmi1`, `bmi2`, `mpx`, `intel_pt`, `xsaves`. **No AVX-512** — relevant to P6's CPU-gating test |
| RAM | 62 GiB total, ~55 GiB available |
| Storage (local) | `/dev/nvme0n1p2`, **btrfs**, on `/` and `/home`: 1.9 TB, 1.7 TB free |
| Storage (repo) | **NFSv3** `ap-juicer:/export/code/trees` on `~/Documents/trees`, 4.2 TB, 3.9 TB free, `vers=3,proto=tcp,hard,rsize=wsize=1M` |
| GPU | Intel UHD 630 (CoffeeLake-H GT2) `[8086:3e9b]` at `00:02.0` — **the only display device** |
| T2 | Apple T2 Bridge Controller `[106b:1801]` and Secure Enclave `[106b:1802]` at `02:00.1`/`02:00.2` |
| OS | Linux Mint 22.3 "Zena" (Ubuntu/Debian derived) |
| Kernel | `7.2.6-1-t2-noble` — **a T2-patched kernel, not stock Ubuntu** |
| Hostname | `pet-power-plant` |
| `/dev/kvm` | present, `crw-rw----+ root:kvm`; user is in group `kvm` (993) |
| sudo | user is in `sudo` (27) |
| QEMU | 8.2.2 (Debian `1:8.2.2+ds-0ubuntu1.18`) |
| OVMF | **4M split only**: `OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd` in `/usr/share/OVMF/`, plus `.ms`, `.secboot`, `.snakeoil` variants. No 2M or combined image. |
| IOMMU | enabled, 14 groups |
| `kvm.ignore_msrs` | `Y` since 2026-09-17, non-persistent — see §3 |
| SSH key | **There is no `~/.ssh/id_*.pub` on this host**, so `image/build-image.sh --generate-ssh-key` made its own: `$MQG_IMAGE_DIR/keys/mqg_rsa`, RSA-4096 because 10.9's OpenSSH 6.2 predates Ed25519. Every guest built here authorizes that key and nothing else, so reaching into a built guest by hand means `ssh -i $MQG_IMAGE_DIR/keys/mqg_rsa`. Not obvious, and not in the usual place anyone would look. |

Two consequences worth stating plainly:

- **Licensing is clean.** Apple's EULA permits virtualizing OS X on
  Apple-branded hardware. This is the sanctioned case, not a gray area.
- **GPU passthrough is not available.** One iGPU, no PCIe slots. See
  `decisions/0001-no-gpu-passthrough.md`.
- **The repository lives on NFS; disk images must not.** See
  `decisions/0003-vm-images-on-local-btrfs.md`.

## 2. Other available hardware

| Host | Role |
|---|---|
| Apple Silicon Mac | P6: pinned QEMU build, local TCG proof, snapshot creation. Note it is faster and less constrained than GitHub's 3-core / 7 GB / 14 GB runners, so it does not give parity. |
| Intel Mac running macOS | P1: runs `get.sh` unmodified to produce the reference installer image. |
| Mavericks-capable Mac | Ground truth for behavior comparison; release sign-off. |

Installer media produced on the Intel Mac lives at
`~/.local/share/mavericks-qemu-guest/media/` with a `SHA256SUMS` beside it.
See the 2026-09-17 entry in `NOTES.md` for what it is and how it was verified.

## 3. Host state changes

Anything here required a `sudo` ask. Record the change, the reason, whether it
survives reboot, and how to revert.

| Date | Change | Persistent? | Revert |
|---|---|---|---|
| 2026-09-17 | `kvm.ignore_msrs=1`, applied by the user via `echo 1 \| sudo tee /sys/module/kvm/parameters/ignore_msrs`. Required by Somlo and OSX-KVM. | **no** — resets on reboot | `echo 0 \| sudo tee /sys/module/kvm/parameters/ignore_msrs` |
| 2026-09-17 | Installed `shellcheck` (by the user) so the test suite can lint shell scripts | yes | `sudo apt remove shellcheck` |
| 2026-09-17 | Installed `nasm` (2.16.01) and `acpica-tools` (`iasl` 20230628), by the user, so `boot/prereqs.sh` is satisfied and OpenCore can be built from source in P3 | yes | `sudo apt remove nasm acpica-tools` |

## 4. Generalization ledger

Other hosts are available to test these against — see `docs/test-hosts.md`,
which says which machine can settle which entry. **Each row below is a
hypothesis, not a fact, until a second host has tried to falsify it.**

**`bin/triangulate.sh` is how a second host tries.** It installs nothing,
needs no root and cleans up after itself, so it is safe to run on a machine
that is doing a real job; `--probe` is the default and touches nothing. Its
report ends in markdown rows shaped like the table below — one per entry
the host could speak to, each CONFIRM, REFUTE or CANNOT-SAY — so a
triangulation run produces an edit to this section rather than a story
about a run. `--json` on several hosts can be diffed.

Every assumption specific to this host. Populate as phases proceed.

| # | Assumption | Phase | What another host would need |
|---|---|---|---|
| G1 | Host is Apple hardware, so running OS X in a VM is licensed | all | Non-Apple hosts are outside Apple's EULA. This is a legal constraint, not a technical one. |
| G2 | Intel CPU with VT-x | P1 | AMD is a known-harder case for macOS guests; the source brief treated it as a hard stop. |
| G3 | Coffee Lake, so the guest CPU model must be masked down to something 10.9 knows | P1, P5 | Any host newer than mid-2014 Macs has the same problem; the specific mask may differ. |
| G4 | 6 physical cores available for pinning, SMT siblings identifiable | P5 | Pinning choices are topology-specific. |
| ~~G5~~ | ~~OVMF is 4M split CODE/VARS at `/usr/share/OVMF/`~~ **RESOLVED 2026-09-17 (P3): no longer an assumption.** We build our own firmware. `boot/build-ovmf.sh` builds `OvmfPkg` out of the same pinned `acidanthera/audk` tree OpenCore comes from, and `p3-full` boots `%BUILD%/firmware/OVMF_CODE.fd` — a path we own, on every host. The distro's `ovmf` package is no longer read by anything that ships. Kept as a struck row rather than deleted so the ledger records that it was retired by a design change, not merely never tested. See the Tier 0 firmware note in the umbrella design §4, and `decisions/0004`. | P1, P3 | ~~Path and layout vary by distro; some ship 2M or combined images.~~ Nothing — unless a host cannot build EDK II at all, which is a build-prerequisite question (`boot/prereqs.sh`), not a firmware-layout one. |
| G6 | QEMU 8.2.2 from Ubuntu | P1–P5 | Behavior may differ across QEMU versions; the GHA phase pins its own. |
| G7 | `t2`-patched kernel | all | Unusual. Any KVM or IOMMU oddity seen here may not reproduce elsewhere — and may be *caused* here. |
| G8 | 62 GB RAM and 1.7 TB free — no pressure on image sizes locally | P2–P5 | P6 deliberately works to a 7 GB / 14 GB budget instead. |
| G9 | The repo is on NFS, so `MQG_IMAGE_DIR` points images at local btrfs instead | P2–P5 | Any host needs images on local storage; the split is the portable part, the path is not. |
| G10 | Local filesystem is btrfs, so `cp --reflink=auto` makes golden promotion near-instant and near-free | P2–P5 | On ext4/xfs without reflink support, promotion is a full copy — slower and costly in space. Budget for it. |
| G11 | btrfs needs `chattr +C` on the image directory to avoid COW fragmentation of qcow2 files | P2–P5 | Not needed on ext4/xfs; harmless to skip elsewhere. |
| G13 | The guest needs **EHCI + UHCI companions**, not `qemu-xhci` — 10.9's `AppleUSBXHCI` cannot drive QEMU's XHCI at all | P1 onward | Applies to any host: this is a guest-OS limitation, not a host one. Portable, and one of the few findings here that generalizes unchanged. |
| G14 | SMBIOS must not be `MacPro5,1` — it loads `AppleTyMCEDriver`, which panics on a non-Xeon CPU. Using `iMac14,2` | P1 onward | Depends on the host CPU not being a Xeon. On a Xeon host, `MacPro5,1` might work and this masking might be unnecessary. |
| ~~G15~~ | ~~Firmware is passed with `-bios`, not as a pflash CODE/VARS pair, so **EFI variables do not persist**~~ **RESOLVED 2026-09-17 (P3):** `p3-full` uses our own split CODE/VARS pair and variables persist — measured across three power cycles, 0 variables to 24, including ones macOS itself wrote. `boot/make-nvram.sh` gives each VM its own copy of the template. | P1 onward | The remaining unknown is narrower and is **not** host-specific: OpenCore still cannot write a *remembered picker default*, because modified keys (`ctrl-2`) never reach it — suspected `UEFI > Input > KeySupport`. That is a `config.plist` question for P4. |
| G17 | `kvm_intel.nested = Y` on this host, so nested virtualization is available without configuration | future | Other hosts may have it disabled; it is a module parameter. Required for VMware Fusion in the guest — see `decisions/0005`. |
| G18 | The guest CPU model is `Penryn`, which predates EPT | P5, future | If VMware Fusion needs EPT, a Nehalem-or-newer model is required and this entry becomes a constraint rather than a preference. |
| G16 | `-device ide-hd,bus=ide.N` on q35 presents as **SATA/AHCI** in the guest, not legacy IDE | P2–P5 | True of q35 generally; a different machine type would change this. Disk Utility reports "Connection Bus: SATA". |
| G12 | The repo is on NFSv3, measured on this host at 60 MB/s bulk vs 567 MB/s local (9.4x) and 18 ms vs 0.06 ms per file creation (156x) — this forced the Tier 2 quarantine (`vendor/reference/` in-repo) off the repo the same way G9 forced disk images off it: `MQG_VENDOR_DIR` now defaults to `$MQG_IMAGE_DIR/vendor-reference`, local btrfs. The 191 MiB `EFI-LEGACY.img` OpenCore blob is read by QEMU on every boot from Task 12 on, and P5 boots dozens of times. | P1–P5 | A host whose repo is already on local disk needs no split at all; one whose repo is remote (NFS or otherwise) needs both images and the quarantine kept local, since both are metadata- or bandwidth-heavy and read/written far more often than the repo's own text files are. |

| G19 | **Two concurrent guest installs wedge one of them.** Observed once, P4: the second build stopped writing to its target disk 6 minutes in and never resumed, while QEMU kept burning 23% of a core and the installer's progress spinner kept animating. Run alone afterwards, the same build completed in 940 s. Memory (62 GiB, 54 available), disk (1.6 TiB free), shared paths (separate `MQG_IMAGE_DIR`s, sockets, ports, NVRAM, target disks) and the privops microVM (finished minutes earlier) are ruled out by evidence. **Cause unproven.** | P4, P6 | **The two candidate causes generalize in opposite directions, which is why this entry matters.** If it is *this host's storage saturating* — two installs streaming off a 6.4 GB raw image into growing sparse qcow2s, all on one NVMe — it is host-specific, and a host with two devices or a slower guest would not hit it. If it is *10.9's `AppleAHCI` having a timeout it cannot recover from*, it is a guest-OS limitation portable to every host we will ever try, exactly like G13. **Settle it before assuming either:** re-run the pair with `cache=none`, or with the image directories on different devices, and watch `/proc/<pid>/io` for the stalled guest rather than its file size. If it is I/O, the guest's read counter stops too; if it is KVM, it does not. Until then, **one build per host** — see `NOTES.md`. |
| G20 | **A second writer to installer media corrupts it, and only a post-unmount checksum notices.** P4, three media builds in six: Apple's `Essentials.pkg` arrived corrupt, in a *different place each time* (110 MB into the file in one build, 1.99 GB in the next), while `rsync` reported success and a read-back through the writing mount passed. The era's logs record an orphaned builder still rsyncing into an image a newer build had started, a hand tool loop-mounting the media and chowning every inode on it, and QEMU itself refusing a second VM's write lock. Linux's `hfsplus` refuses a second read-write mount on its own (it clears `kHFSVolumeUnmountedBit` on mount, and will not mount read-write without it) — **measured**. So the vectors that matter are the two that get round that: `hfs_mark_clean`, whose whole purpose is to force the bit back, and a QEMU guest, which is not the Linux driver — the media was attached without `snapshot=on` until 2026-09-19 and macOS wrote a `.Spotlight-V100` store onto it. Ten later builds at that same tight geometry, run one at a time on an idle host and checked file-by-file against the Mac-produced reference, were **byte-perfect** — so the build itself is not what did it. See the Task 34 entry in `NOTES.md`. | P4, P5, P6 | **Portable, like G13 — it is a property of the file and the filesystem, not of this machine.** Any host that boots media it also builds needs the same three things: `snapshot=on` wherever media is attached to a guest, one builder per image file (`media/build-installer-img.sh` now takes a lock), and a verification that reads the finished media from a fresh mount and checks it against a constant rather than against what the build itself read (`media/apple-packages.sha256`). |

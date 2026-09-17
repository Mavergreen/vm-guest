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

## 3. Host state changes

Anything here required a `sudo` ask. Record the change, the reason, whether it
survives reboot, and how to revert.

| Date | Change | Persistent? | Revert |
|---|---|---|---|
| 2026-09-17 | `kvm.ignore_msrs=1`, applied by the user via `echo 1 \| sudo tee /sys/module/kvm/parameters/ignore_msrs`. Required by Somlo and OSX-KVM. | **no** — resets on reboot | `echo 0 \| sudo tee /sys/module/kvm/parameters/ignore_msrs` |
| 2026-09-17 | Installed `shellcheck` (by the user) so the test suite can lint shell scripts | yes | `sudo apt remove shellcheck` |

## 4. Generalization ledger

Every assumption specific to this host. Populate as phases proceed.

| # | Assumption | Phase | What another host would need |
|---|---|---|---|
| G1 | Host is Apple hardware, so running OS X in a VM is licensed | all | Non-Apple hosts are outside Apple's EULA. This is a legal constraint, not a technical one. |
| G2 | Intel CPU with VT-x | P1 | AMD is a known-harder case for macOS guests; the source brief treated it as a hard stop. |
| G3 | Coffee Lake, so the guest CPU model must be masked down to something 10.9 knows | P1, P5 | Any host newer than mid-2014 Macs has the same problem; the specific mask may differ. |
| G4 | 6 physical cores available for pinning, SMT siblings identifiable | P5 | Pinning choices are topology-specific. |
| G5 | OVMF is 4M split CODE/VARS at `/usr/share/OVMF/` | P1, P3 | Path and layout vary by distro; some ship 2M or combined images. |
| G6 | QEMU 8.2.2 from Ubuntu | P1–P5 | Behavior may differ across QEMU versions; the GHA phase pins its own. |
| G7 | `t2`-patched kernel | all | Unusual. Any KVM or IOMMU oddity seen here may not reproduce elsewhere — and may be *caused* here. |
| G8 | 62 GB RAM and 1.7 TB free — no pressure on image sizes locally | P2–P5 | P6 deliberately works to a 7 GB / 14 GB budget instead. |
| G9 | The repo is on NFS, so `MQG_IMAGE_DIR` points images at local btrfs instead | P2–P5 | Any host needs images on local storage; the split is the portable part, the path is not. |
| G10 | Local filesystem is btrfs, so `cp --reflink=auto` makes golden promotion near-instant and near-free | P2–P5 | On ext4/xfs without reflink support, promotion is a full copy — slower and costly in space. Budget for it. |
| G11 | btrfs needs `chattr +C` on the image directory to avoid COW fragmentation of qcow2 files | P2–P5 | Not needed on ext4/xfs; harmless to skip elsewhere. |
